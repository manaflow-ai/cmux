import AppKit
import CoreText
import Foundation
import GhosttyKit
import QuartzCore

/// Safe across Ghostty's manual-I/O callback thread because the continuation
/// is Sendable and the epoch value lives in a Rust atomic gate.
final class GhosttyTerminalInputRelay: @unchecked Sendable {
  private let continuation: AsyncStream<QueuedTerminalInput>.Continuation
  private let dropContinuation: AsyncStream<Void>.Continuation
  private let epochGate: OpaquePointer
  private let maximumQueuedBytes: Int

  init(
    continuation: AsyncStream<QueuedTerminalInput>.Continuation,
    dropContinuation: AsyncStream<Void>.Continuation,
    maximumQueuedBytes: Int = Int(CMUX_FRONTEND_TERMINAL_INPUT_QUEUE_MAX_BYTES_VALUE)
  ) {
    self.continuation = continuation
    self.dropContinuation = dropContinuation
    self.maximumQueuedBytes = max(0, maximumQueuedBytes)
    guard let epochGate = cmux_frontend_input_epoch_gate_new() else {
      preconditionFailure("The terminal input epoch gate could not be created.")
    }
    self.epochGate = epochGate
  }

  deinit {
    cmux_frontend_input_epoch_gate_free(epochGate)
  }

  @discardableResult
  func send(_ data: Data) -> Bool {
    send(.bytes(data))
  }

  @discardableResult
  func send(_ input: TerminalInput) -> Bool {
    let byteCount = input.queuedByteCount
    var epoch: UInt64 = 0
    guard cmux_frontend_input_epoch_gate_try_reserve_bytes_with_epoch(
      epochGate,
      byteCount,
      maximumQueuedBytes,
      &epoch
    ) else {
      dropContinuation.yield()
      return false
    }
    switch continuation.yield(QueuedTerminalInput(
      input: input,
      epoch: epoch,
      byteCount: byteCount
    )) {
    case .enqueued:
      return true
    case .dropped, .terminated:
      cmux_frontend_input_epoch_gate_release_bytes(epochGate, byteCount)
      dropContinuation.yield()
      return false
    @unknown default:
      cmux_frontend_input_epoch_gate_release_bytes(epochGate, byteCount)
      dropContinuation.yield()
      return false
    }
  }

  func didDequeue(_ input: QueuedTerminalInput) {
    cmux_frontend_input_epoch_gate_release_bytes(epochGate, input.byteCount)
  }

  func beginEpoch(_ epoch: UInt64) {
    cmux_frontend_input_epoch_gate_store(epochGate, epoch)
  }
}

private final class GhosttyRemoteSurfaceContext: Sendable {
  let inputRelay: GhosttyTerminalInputRelay

  init(inputRelay: GhosttyTerminalInputRelay) {
    self.inputRelay = inputRelay
  }
}

/// `@unchecked Sendable` is safe because the owning AppKit view creates,
/// replaces, and releases the surface on the main actor. Deinit runs only
/// after that view has released its sole lifetime reference.
private final class GhosttyRemoteSurfaceLifetime: @unchecked Sendable {
  var surface: ghostty_surface_t?
  private let callbackContext: GhosttyRemoteSurfaceContext

  init(callbackContext: GhosttyRemoteSurfaceContext) {
    self.callbackContext = callbackContext
  }

  func replace(with replacement: ghostty_surface_t?) {
    if let surface {
      ghostty_surface_free(surface)
    }
    surface = replacement
  }

  deinit {
    if let surface {
      ghostty_surface_free(surface)
    }
  }
}

private let ghosttyRemoteIOWriteCallback:
  @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UInt
  ) -> Void = { userdata, bytes, length in
    guard let userdata, let bytes, length > 0 else { return }
    let context = Unmanaged<GhosttyRemoteSurfaceContext>
      .fromOpaque(userdata)
      .takeUnretainedValue()
    let data = Data(bytes: bytes, count: Int(length))
    context.inputRelay.send(data)
  }

private func nativeGhosttyModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
  var value = GHOSTTY_MODS_NONE.rawValue
  if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
  if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
  if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
  if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
  if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }

  let raw = flags.rawValue
  if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { value |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
  if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { value |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
  if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { value |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
  if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { value |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
  return ghostty_input_mods_e(value)
}

func nativeModifierKeyIsPressed(
  keyCode: UInt16,
  modifierFlags: NSEvent.ModifierFlags
) -> Bool? {
  let rawMask: UInt
  switch keyCode {
  case 0x39: return modifierFlags.contains(.capsLock)
  case 0x38: rawMask = UInt(NX_DEVICELSHIFTKEYMASK)
  case 0x3C: rawMask = UInt(NX_DEVICERSHIFTKEYMASK)
  case 0x3B: rawMask = UInt(NX_DEVICELCTLKEYMASK)
  case 0x3E: rawMask = UInt(NX_DEVICERCTLKEYMASK)
  case 0x3A: rawMask = UInt(NX_DEVICELALTKEYMASK)
  case 0x3D: rawMask = UInt(NX_DEVICERALTKEYMASK)
  case 0x37: rawMask = UInt(NX_DEVICELCMDKEYMASK)
  case 0x36: rawMask = UInt(NX_DEVICERCMDKEYMASK)
  default: return nil
  }
  return modifierFlags.rawValue & rawMask != 0
}

func nativeSurfaceShouldHaveFocus(
  applicationActive: Bool,
  windowKey: Bool,
  firstResponder: Bool
) -> Bool {
  applicationActive && windowKey && firstResponder
}

private func nativeEventModifiers(_ modifiers: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
  var result: NSEvent.ModifierFlags = []
  if modifiers.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { result.insert(.shift) }
  if modifiers.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { result.insert(.control) }
  if modifiers.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { result.insert(.option) }
  if modifiers.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { result.insert(.command) }
  return result
}

private func nativeGhosttyText(_ text: ghostty_text_s) -> String {
  guard let pointer = text.text, text.text_len > 0 else { return "" }
  return String(
    decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)),
    as: UTF8.self
  )
}

extension NSEvent {
  fileprivate func nativeGhosttyKeyEvent(
    _ action: ghostty_input_action_e,
    translationModifiers: NSEvent.ModifierFlags? = nil
  ) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(keyCode)
    key.text = nil
    key.composing = false
    key.mods = nativeGhosttyModifiers(modifierFlags)
    key.consumed_mods = nativeGhosttyModifiers(
      (translationModifiers ?? modifierFlags).subtracting([.control, .command])
    )
    if type == .keyDown || type == .keyUp,
      let character = characters(byApplyingModifiers: [])?.unicodeScalars.first
    {
      key.unshifted_codepoint = character.value
    }
    return key
  }

  fileprivate var nativeGhosttyCharacters: String? {
    guard let characters else { return nil }
    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      if scalar.value < 0x20 {
        return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
      }
      if (0xF700...0xF8FF).contains(scalar.value) {
        return nil
      }
    }
    return characters
  }
}

/// AppKit host for a libghostty manual-I/O surface. The surface owns terminal
/// emulation, styling, selection, input encoding, scrollback, and Metal
/// rendering. Rust owns only transport ordering and the remote PTY stream.
struct MarkedTextRanges: Equatable {
  let marked: NSRange
  let selected: NSRange

  static func updated(
    textLength: Int,
    selectedRange: NSRange,
    replacementRange: NSRange,
    currentMarkedRange: NSRange,
    fallbackSelection: NSRange
  ) -> MarkedTextRanges {
    let unavailable = NSRange(location: NSNotFound, length: 0)
    let length = max(0, textLength)
    guard length > 0 else { return MarkedTextRanges(marked: unavailable, selected: unavailable) }

    let requestedBase: Int
    if replacementRange.location != NSNotFound {
      requestedBase = replacementRange.location
    } else if currentMarkedRange.location != NSNotFound {
      requestedBase = currentMarkedRange.location
    } else if fallbackSelection.location != NSNotFound {
      requestedBase = fallbackSelection.location
    } else {
      requestedBase = 0
    }
    let base = min(max(0, requestedBase), Int.max - length)
    let requestedSelection = selectedRange.location == NSNotFound
      ? length : selectedRange.location
    let relativeLocation = min(max(0, requestedSelection), length)
    let relativeLength = min(max(0, selectedRange.length), length - relativeLocation)
    return MarkedTextRanges(
      marked: NSRange(location: base, length: length),
      selected: NSRange(location: base + relativeLocation, length: relativeLength)
    )
  }
}

final class GhosttyRemoteSurfaceView: NSView, @preconcurrency NSTextInputClient {
  var onGeometryChanged: ((TerminalGeometry) -> Void)?
  private(set) var initializationError: String?

  private let runtime: NativeGhosttyRuntime?
  private let localization: Localization
  private let callbackContext: GhosttyRemoteSurfaceContext
  private let surfaceLifetime: GhosttyRemoteSurfaceLifetime
  private var surface: ghostty_surface_t? { surfaceLifetime.surface }
  private var markedText = NSMutableAttributedString()
  private var markedTextRange = NSRange(location: NSNotFound, length: 0)
  private var markedTextSelection = NSRange(location: NSNotFound, length: 0)
  private var keyTextAccumulator: [String]?
  private var locallyConsumedKeyCodes: Set<UInt16> = []
  private var lastReportedGeometry: TerminalGeometry?
  private weak var focusObservedWindow: NSWindow?
  private var sentRightMousePress = false
  private var ready = false
  private(set) var renderStreamValid = false

  override var acceptsFirstResponder: Bool { true }

  init(
    runtime: NativeGhosttyRuntime?,
    inputRelay: GhosttyTerminalInputRelay,
    localization: Localization = .fallback
  ) {
    self.runtime = runtime
    self.localization = localization
    let callbackContext = GhosttyRemoteSurfaceContext(inputRelay: inputRelay)
    self.callbackContext = callbackContext
    surfaceLifetime = GhosttyRemoteSurfaceLifetime(callbackContext: callbackContext)
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    if runtime == nil {
      initializationError = localization.text(
        "error.ghostty_runtime",
        "The embedded Ghostty renderer could not start."
      )
    }
    registerForDraggedTypes([.string, .fileURL])
    updateTrackingAreas()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(focusContextDidChange),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(focusContextDidChange),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func apply(_ event: TerminalRenderEvent) {
    switch event.kind {
    case .reset:
      callbackContext.inputRelay.beginEpoch(event.inputEpoch)
      clearLocalInputState()
      ready = false
      renderStreamValid = false
      lastReportedGeometry = nil
      surfaceLifetime.replace(with: nil)
      guard let reset = NativeKittyResetMetadata.decode(event.payload) else {
        failClosedForInvalidSnapshot()
        return
      }
      recreateSurface()
      setGrid(event.geometry)
      guard let surface else { return }
      guard restoreKittyReplay(surface: surface, metadata: reset) else {
        failClosedForInvalidSnapshot()
        return
      }
      renderStreamValid = true
      updateSurfaceSize(reportGeometry: true)
    case .bytes:
      guard renderStreamValid else { return }
      processOutput(event.payload)
    case .resize:
      guard renderStreamValid else { return }
      setGrid(event.geometry)
    case .ready:
      guard renderStreamValid, surface != nil else { return }
      ready = true
      syncSurfaceFocus()
      if let surface {
        ghostty_surface_refresh(surface)
      }
    case .exit:
      callbackContext.inputRelay.beginEpoch(event.inputEpoch)
      clearLocalInputState()
      ready = false
      renderStreamValid = false
    case .inputEpoch:
      callbackContext.inputRelay.beginEpoch(event.inputEpoch)
      clearLocalInputState()
      ready = false
      renderStreamValid = false
    }
  }

  private func clearLocalInputState() {
    markedText.mutableString.setString("")
    markedTextRange = NSRange(location: NSNotFound, length: 0)
    markedTextSelection = NSRange(location: NSNotFound, length: 0)
    keyTextAccumulator = nil
    locallyConsumedKeyCodes.removeAll()
    sentRightMousePress = false
  }

  private func failClosedForInvalidSnapshot() {
    // Transport epochs start at one, so zero fences this failed snapshot.
    callbackContext.inputRelay.beginEpoch(0)
    clearLocalInputState()
    ready = false
    renderStreamValid = false
    lastReportedGeometry = nil
    surfaceLifetime.replace(with: nil)
    initializationError = localization.text(
      "error.terminal_snapshot",
      "The terminal snapshot was invalid."
    )
  }

  private func restoreKittyReplay(
    surface: ghostty_surface_t,
    metadata: NativeKittyResetMetadata
  ) -> Bool {
    let aliases = metadata.aliases.map {
      ghostty_surface_kitty_image_alias(image_id: $0.0, image_number: $0.1)
    }
    let limits = ghostty_surface_kitty_graphics_limits(
      image_bytes: metadata.limits.0,
      inflight_bytes: metadata.limits.1,
      images: metadata.limits.2,
      placements: metadata.limits.3
    )
    let cursors = ghostty_surface_kitty_image_id_cursor_state(
      replay: ghostty_surface_kitty_image_id_cursors(
        primary: metadata.replayNextIDs.0,
        alternate: metadata.replayNextIDs.1
      ),
      next: ghostty_surface_kitty_image_id_cursors(
        primary: metadata.nextIDs.0,
        alternate: metadata.nextIDs.1
      )
    )
    return metadata.replay.withUnsafeBytes { bytes in
      aliases.withUnsafeBufferPointer { aliasBuffer in
        ghostty_surface_restore_kitty_replay(
          surface,
          bytes.bindMemory(to: CChar.self).baseAddress,
          UInt(bytes.count),
          metadata.replayCursorOffset,
          limits,
          cursors,
          aliasBuffer.baseAddress,
          UInt(aliases.count)
        )
      }
    }
  }

  private func recreateSurface() {
    ready = false
    lastReportedGeometry = nil
    surfaceLifetime.replace(with: nil)
    guard let runtime else { return }

    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(self).toOpaque()
      ))
    config.userdata = Unmanaged.passUnretained(callbackContext).toOpaque()
    config.scale_factor = Double(
      window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    )
    config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
    config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
    config.io_write_cb = ghosttyRemoteIOWriteCallback
    config.io_write_userdata = Unmanaged.passUnretained(callbackContext).toOpaque()
    surfaceLifetime.replace(with: ghostty_surface_new(runtime.app, &config))
    if surface == nil {
      initializationError = localization.text(
        "error.ghostty_surface",
        "The embedded Ghostty terminal surface could not start."
      )
      return
    }
    initializationError = nil
    updateSurfaceSize(reportGeometry: false)
  }

  private func processOutput(_ data: Data) {
    guard let surface, !data.isEmpty else { return }
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
      ghostty_surface_process_output(surface, base, UInt(bytes.count))
    }
  }

  private func setGrid(_ geometry: TerminalGeometry) {
    guard let surface else { return }
    var resolved = ghostty_surface_size_s()
    _ = ghostty_surface_set_grid_size(surface, geometry.cols, geometry.rows, &resolved)
  }

  override func layout() {
    super.layout()
    updateSurfaceSize(reportGeometry: true)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateWindowFocusObservation()
    updateSurfaceSize(reportGeometry: true)
    syncSurfaceFocus()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let surface else { return }
    let scale = window?.backingScaleFactor ?? 1
    layer?.contentsScale = scale
    ghostty_surface_set_content_scale(surface, scale, scale)
    updateSurfaceSize(reportGeometry: true)
  }

  private func updateSurfaceSize(reportGeometry: Bool) {
    guard let surface, bounds.width > 1, bounds.height > 1 else { return }
    let backing = convertToBacking(bounds)
    let width = UInt32(max(1, min(CGFloat(UInt32.max), backing.width.rounded())))
    let height = UInt32(max(1, min(CGFloat(UInt32.max), backing.height.rounded())))
    ghostty_surface_set_size(surface, width, height)
    guard reportGeometry else { return }
    let size = ghostty_surface_size(surface)
    let geometry = TerminalGeometry(cols: max(1, size.columns), rows: max(1, size.rows))
    guard geometry != lastReportedGeometry else { return }
    lastReportedGeometry = geometry
    onGeometryChanged?(geometry)
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { syncSurfaceFocus(firstResponder: true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { syncSurfaceFocus(firstResponder: false) }
    return resigned
  }

  private func updateWindowFocusObservation() {
    let center = NotificationCenter.default
    if let focusObservedWindow {
      center.removeObserver(
        self,
        name: NSWindow.didBecomeKeyNotification,
        object: focusObservedWindow
      )
      center.removeObserver(
        self,
        name: NSWindow.didResignKeyNotification,
        object: focusObservedWindow
      )
    }
    focusObservedWindow = window
    guard let window else { return }
    center.addObserver(
      self,
      selector: #selector(focusContextDidChange),
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )
    center.addObserver(
      self,
      selector: #selector(focusContextDidChange),
      name: NSWindow.didResignKeyNotification,
      object: window
    )
  }

  @objc private func focusContextDidChange(_ notification: Notification) {
    syncSurfaceFocus()
  }

  private func syncSurfaceFocus(firstResponder: Bool? = nil) {
    guard ready, let surface else { return }
    let focused = nativeSurfaceShouldHaveFocus(
      applicationActive: NSApp.isActive,
      windowKey: window?.isKeyWindow == true,
      firstResponder: firstResponder ?? (window?.firstResponder === self)
    )
    ghostty_surface_set_focus(surface, focused)
  }

  override func keyDown(with event: NSEvent) {
    guard ready, let surface else { return }
    if event.modifierFlags.contains(.command) {
      locallyConsumedKeyCodes.insert(event.keyCode)
      super.keyDown(with: event)
      return
    }

    let translated = nativeEventModifiers(
      ghostty_surface_key_translation_mods(surface, nativeGhosttyModifiers(event.modifierFlags))
    )
    var translatedFlags = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translated.contains(flag) {
        translatedFlags.insert(flag)
      } else {
        translatedFlags.remove(flag)
      }
    }
    let translatedEvent =
      translatedFlags == event.modifierFlags
      ? event
      : NSEvent.keyEvent(
        with: event.type,
        location: event.locationInWindow,
        modifierFlags: translatedFlags,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: event.characters(byApplyingModifiers: translatedFlags) ?? "",
        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
        isARepeat: event.isARepeat,
        keyCode: event.keyCode
      ) ?? event

    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    let hadMarkedText = hasMarkedText()
    keyTextAccumulator = []
    interpretKeyEvents([translatedEvent])
    let accumulated = keyTextAccumulator ?? []
    keyTextAccumulator = nil
    syncPreedit(clearIfNeeded: hadMarkedText)
    let composing = hasMarkedText() || hadMarkedText

    if accumulated.isEmpty {
      _ = sendKey(
        event,
        translatedEvent: translatedEvent,
        action: action,
        text: translatedEvent.nativeGhosttyCharacters,
        composing: composing
      )
    } else {
      for text in accumulated where !shouldSuppressControl(text, composing: composing) {
        _ = sendKey(
          event,
          translatedEvent: translatedEvent,
          action: action,
          text: text,
          composing: false
        )
      }
    }
  }

  override func keyUp(with event: NSEvent) {
    if locallyConsumedKeyCodes.remove(event.keyCode) != nil
      || event.modifierFlags.contains(.command)
    {
      super.keyUp(with: event)
      return
    }
    _ = sendKey(event, action: GHOSTTY_ACTION_RELEASE)
  }

  override func flagsChanged(with event: NSEvent) {
    guard let pressed = nativeModifierKeyIsPressed(
      keyCode: event.keyCode,
      modifierFlags: event.modifierFlags
    ) else { return }
    guard !hasMarkedText() else { return }
    let action: ghostty_input_action_e =
      pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    _ = sendKey(event, action: action)
  }

  private func sendKey(
    _ event: NSEvent,
    translatedEvent: NSEvent? = nil,
    action: ghostty_input_action_e,
    text: String? = nil,
    composing: Bool = false
  ) -> Bool {
    guard ready, let surface else { return false }
    var key = event.nativeGhosttyKeyEvent(
      action,
      translationModifiers: translatedEvent?.modifierFlags
    )
    key.composing = composing
    if let text, let first = text.utf8.first, first >= 0x20 {
      return text.withCString { pointer in
        key.text = pointer
        return ghostty_surface_key(surface, key)
      }
    }
    return ghostty_surface_key(surface, key)
  }

  private func shouldSuppressControl(_ text: String, composing: Bool) -> Bool {
    guard composing else { return false }
    let scalars = text.unicodeScalars
    guard let first = scalars.first,
      scalars.index(after: scalars.startIndex) == scalars.endIndex
    else { return false }
    return first.value < 0x20
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "v":
      locallyConsumedKeyCodes.insert(event.keyCode)
      paste(nil)
      return true
    case "c":
      locallyConsumedKeyCodes.insert(event.keyCode)
      copy(nil)
      return true
    default:
      return super.performKeyEquivalent(with: event)
    }
  }

  @objc func paste(_ sender: Any?) {
    _ = sender
    guard ready, let surface,
      let text = NSPasteboard.general.string(forType: .string),
      !text.isEmpty
    else { return }
    text.withCString { pointer in
      ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
    }
  }

  @objc func copy(_ sender: Any?) {
    _ = sender
    guard let surface else { return }
    var selected = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selected) else { return }
    defer { ghostty_surface_free_text(surface, &selected) }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(nativeGhosttyText(selected), forType: .string)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if event.clickCount == 1 { sendMousePosition(event) }
    sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event: event)
  }

  override func mouseUp(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard ready, let surface else {
      super.rightMouseDown(with: event)
      return
    }
    sentRightMousePress = false
    guard !event.modifierFlags.contains(.shift) else {
      super.rightMouseDown(with: event)
      return
    }
    window?.makeFirstResponder(self)
    sendMousePosition(event)
    sentRightMousePress = true
    if !ghostty_surface_mouse_button(
      surface,
      GHOSTTY_MOUSE_PRESS,
      GHOSTTY_MOUSE_RIGHT,
      nativeGhosttyModifiers(event.modifierFlags)
    ) {
      super.rightMouseDown(with: event)
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    guard ready, sentRightMousePress, let surface else {
      super.rightMouseUp(with: event)
      return
    }
    sentRightMousePress = false
    if !ghostty_surface_mouse_button(
      surface,
      GHOSTTY_MOUSE_RELEASE,
      GHOSTTY_MOUSE_RIGHT,
      nativeGhosttyModifiers(event.modifierFlags)
    ) {
      super.rightMouseUp(with: event)
    }
  }

  override func otherMouseDown(with event: NSEvent) {
    sendMousePosition(event)
    sendMouseButton(GHOSTTY_MOUSE_PRESS, mouseButton(event.buttonNumber), event: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_RELEASE, mouseButton(event.buttonNumber), event: event)
  }

  private func sendMouseButton(
    _ state: ghostty_input_mouse_state_e,
    _ button: ghostty_input_mouse_button_e,
    event: NSEvent
  ) {
    guard ready, let surface else { return }
    ghostty_surface_mouse_button(
      surface, state, button, nativeGhosttyModifiers(event.modifierFlags))
  }

  private func mouseButton(_ number: Int) -> ghostty_input_mouse_button_e {
    switch number {
    case 0: GHOSTTY_MOUSE_LEFT
    case 1: GHOSTTY_MOUSE_RIGHT
    case 2: GHOSTTY_MOUSE_MIDDLE
    case 3: GHOSTTY_MOUSE_FOUR
    case 4: GHOSTTY_MOUSE_FIVE
    case 5: GHOSTTY_MOUSE_SIX
    case 6: GHOSTTY_MOUSE_SEVEN
    case 7: GHOSTTY_MOUSE_EIGHT
    case 8: GHOSTTY_MOUSE_NINE
    case 9: GHOSTTY_MOUSE_TEN
    case 10: GHOSTTY_MOUSE_ELEVEN
    default: GHOSTTY_MOUSE_UNKNOWN
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
        owner: self
      ))
  }

  override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
  override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
  override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
  override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

  override func mouseExited(with event: NSEvent) {
    guard ready, let surface, NSEvent.pressedMouseButtons == 0 else { return }
    ghostty_surface_mouse_pos(surface, -1, -1, nativeGhosttyModifiers(event.modifierFlags))
  }

  private func sendMousePosition(_ event: NSEvent) {
    guard ready, let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface,
      point.x,
      bounds.height - point.y,
      nativeGhosttyModifiers(event.modifierFlags)
    )
  }

  override func scrollWheel(with event: NSEvent) {
    guard ready, let surface else { return }
    var x = event.scrollingDeltaX
    var y = event.scrollingDeltaY
    if event.hasPreciseScrollingDeltas {
      x *= 2
      y *= 2
    }
    let phase: Int32
    switch event.momentumPhase {
    case .began: phase = 1
    case .stationary: phase = 2
    case .changed: phase = 3
    case .ended: phase = 4
    case .cancelled: phase = 5
    case .mayBegin: phase = 6
    default: phase = 0
    }
    let modifiers = (event.hasPreciseScrollingDeltas ? 1 : 0) | (phase << 1)
    ghostty_surface_mouse_scroll(surface, x, y, modifiers)
  }

  override func pressureChange(with event: NSEvent) {
    guard ready, let surface else { return }
    ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    !ready || sender.draggingPasteboard.string(forType: .string) == nil ? [] : .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard ready, let surface, let text = sender.draggingPasteboard.string(forType: .string) else {
      return false
    }
    text.withCString { pointer in
      ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
    }
    return true
  }

  func hasMarkedText() -> Bool { markedText.length > 0 }

  func markedRange() -> NSRange {
    markedText.length == 0
      ? NSRange(location: NSNotFound, length: 0) : markedTextRange
  }

  func selectedRange() -> NSRange {
    if markedText.length > 0 { return markedTextSelection }
    // The terminal selection is not editable NSTextInputClient storage. Use a
    // stable virtual UTF-16 insertion point for input-method composition.
    return NSRange(location: 0, length: 0)
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let fallbackSelection = self.selectedRange()
    switch string {
    case let value as NSAttributedString:
      markedText = NSMutableAttributedString(attributedString: value)
    case let value as String:
      markedText = NSMutableAttributedString(string: value)
    default:
      return
    }
    let ranges = MarkedTextRanges.updated(
      textLength: markedText.length,
      selectedRange: selectedRange,
      replacementRange: replacementRange,
      currentMarkedRange: markedTextRange,
      fallbackSelection: fallbackSelection
    )
    markedTextRange = ranges.marked
    markedTextSelection = ranges.selected
    if keyTextAccumulator == nil { syncPreedit() }
  }

  func unmarkText() {
    guard markedText.length > 0 else { return }
    markedText.mutableString.setString("")
    markedTextRange = NSRange(location: NSNotFound, length: 0)
    markedTextSelection = NSRange(location: NSNotFound, length: 0)
    syncPreedit()
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    guard markedText.length > 0,
      markedTextRange.location != NSNotFound,
      range.location != NSNotFound
    else { return nil }
    let intersection = NSIntersectionRange(range, markedTextRange)
    guard intersection.length > 0 else { return nil }
    actualRange?.pointee = intersection
    return markedText.attributedSubstring(from: NSRange(
      location: intersection.location - markedTextRange.location,
      length: intersection.length
    ))
  }

  func characterIndex(for point: NSPoint) -> Int {
    _ = point
    let selected = selectedRange()
    return selected.location == NSNotFound ? 0 : selected.location
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    if markedText.length > 0, range.location != NSNotFound {
      let intersection = NSIntersectionRange(range, markedTextRange)
      actualRange?.pointee = intersection.length > 0 ? intersection : markedTextSelection
    } else {
      actualRange?.pointee = selectedRange()
    }
    guard let surface else { return window?.convertToScreen(convert(bounds, to: nil)) ?? bounds }
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    let local = NSRect(x: x, y: bounds.height - y, width: width, height: max(1, height))
    let inWindow = convert(local, to: nil)
    return window?.convertToScreen(inWindow) ?? inWindow
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    _ = replacementRange
    let text: String
    switch string {
    case let value as NSAttributedString: text = value.string
    case let value as String: text = value
    default: return
    }
    unmarkText()
    if keyTextAccumulator != nil {
      keyTextAccumulator?.append(text)
      return
    }
    guard ready, let surface, !text.isEmpty else { return }
    text.withCString { pointer in
      ghostty_surface_text_input(surface, pointer, UInt(text.utf8.count))
    }
  }

  override func doCommand(by selector: Selector) {
    _ = selector
  }

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }
    if markedText.length > 0 {
      let text = markedText.string
      text.withCString { pointer in
        ghostty_surface_preedit(surface, pointer, UInt(text.utf8.count))
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }
}

struct NativeKittyResetMetadata: Sendable {
  let replay: Data
  let aliases: [(UInt32, UInt32)]
  let limits: (UInt64, UInt64, UInt64, UInt64)
  let replayCursorOffset: UInt32
  let replayNextIDs: (UInt32, UInt32)
  let nextIDs: (UInt32, UInt32)

  static func decode(_ data: Data) -> NativeKittyResetMetadata? {
    guard data.count >= 4 + 1 + 4 + 2 + 32 + 20, data.prefix(4) == Data("CMNR".utf8), data[4] == 1 else { return nil }
    var offset = 5
    func take(_ count: Int) -> Data? { guard offset + count <= data.count else { return nil }; defer { offset += count }; return data[offset..<(offset + count)] }
    func u16() -> UInt16? { take(2).map { $0.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } } }
    func u32() -> UInt32? { take(4).map { $0.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } } }
    func u64() -> UInt64? { take(8).map { $0.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } } }
    guard let replayLength = u32(), let aliasCount = u16(), let imageBytes = u64(), let inflightBytes = u64(), let images = u64(), let placements = u64(), let replayOffset = u32(), let replayPrimary = u32(), let nextPrimary = u32(), let replayAlternate = u32(), let nextAlternate = u32() else { return nil }
    var aliases: [(UInt32, UInt32)] = []
    for _ in 0..<aliasCount { guard let imageID = u32(), let imageNumber = u32() else { return nil }; aliases.append((imageID, imageNumber)) }
    guard let replay = take(Int(replayLength)), offset == data.count else { return nil }
    return NativeKittyResetMetadata(replay: replay, aliases: aliases, limits: (imageBytes, inflightBytes, images, placements), replayCursorOffset: replayOffset, replayNextIDs: (replayPrimary, replayAlternate), nextIDs: (nextPrimary, nextAlternate))
  }
}
