import Foundation
import Observation

enum TerminalInput: Sendable {
  case bytes(Data)
  case paste(String)
  case key(chord: String, repeat: Bool)
}

struct QueuedTerminalInput: Sendable {
  let input: TerminalInput
  let epoch: UInt64
}

struct TerminalGeometry: Equatable, Sendable {
  let cols: UInt16
  let rows: UInt16
}

struct NewestResizeQueue: Sendable {
  private(set) var pending: TerminalGeometry?

  mutating func submit(_ geometry: TerminalGeometry) -> Bool {
    let shouldStart = pending == nil
    pending = geometry
    return shouldStart
  }

  mutating func take() -> TerminalGeometry? {
    defer { pending = nil }
    return pending
  }
}

func terminalGeometry(width: CGFloat, height: CGFloat) -> TerminalGeometry {
  TerminalGeometry(
    cols: UInt16(max(1, min(10_000, Int(max(0, width - 16) / 8.4)))),
    rows: UInt16(max(1, min(10_000, Int(max(0, height - 16) / 17.0))))
  )
}

enum TerminalAttachmentDisposition: Equatable, Sendable {
  case active
  case exited
  case reconnectRequired
}

func terminalAttachmentDisposition(
  didExit: Bool,
  connectionClosed: Bool
) -> TerminalAttachmentDisposition {
  if didExit { return .exited }
  if connectionClosed { return .reconnectRequired }
  return .active
}

@MainActor
@Observable
final class NativeTerminalModel {
  private static let maxRenderBatchesPerPass = 1

  let terminalID: String
  private(set) var errorMessage = ""
  private(set) var isAttached = false
  private(set) var didExit = false

  @ObservationIgnored private let service: FrontendService
  @ObservationIgnored private let localization: Localization
  @ObservationIgnored private var handle: TerminalHandle?
  @ObservationIgnored private var updateTask: Task<Void, Never>?
  @ObservationIgnored private var inputTask: Task<Void, Never>?
  @ObservationIgnored private var attachTask: Task<Void, Never>?
  @ObservationIgnored private var resizeTask: Task<Void, Never>?
  @ObservationIgnored private var drainTask: Task<Void, Never>?
  @ObservationIgnored private var inputDropTask: Task<Void, Never>?
  @ObservationIgnored private var drainRequested = false
  @ObservationIgnored private var inputErrorMessage: String?
  @ObservationIgnored private var resizeQueue = NewestResizeQueue()
  @ObservationIgnored private let inputStream: AsyncStream<QueuedTerminalInput>
  @ObservationIgnored private let inputContinuation:
    AsyncStream<QueuedTerminalInput>.Continuation
  @ObservationIgnored private let inputRelay: GhosttyTerminalInputRelay
  @ObservationIgnored private let inputDropStream: AsyncStream<Void>
  @ObservationIgnored private let inputDropContinuation: AsyncStream<Void>.Continuation
  @ObservationIgnored private var latestGeometry: TerminalGeometry?
  @ObservationIgnored private var didStart = false
  @ObservationIgnored private var isShuttingDown = false
  @ObservationIgnored let surfaceView: GhosttyRemoteSurfaceView

  var viewState: NativeTerminalViewState {
    NativeTerminalViewState(
      surfaceView: surfaceView,
      errorMessage: errorMessage,
      isAttached: isAttached,
      didExit: didExit,
      retryAttach: !isAttached && !errorMessage.isEmpty ? { [weak self] in self?.attach() } : nil
    )
  }

  init(
    terminalID: String,
    service: FrontendService,
    runtime: NativeGhosttyRuntime?,
    localization: Localization = .fallback
  ) {
    self.terminalID = terminalID
    self.service = service
    self.localization = localization
    let input = AsyncStream<QueuedTerminalInput>.makeStream(
      bufferingPolicy: .bufferingOldest(256)
    )
    let inputDrops = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    inputStream = input.stream
    inputContinuation = input.continuation
    inputDropStream = inputDrops.stream
    inputDropContinuation = inputDrops.continuation
    let inputRelay = GhosttyTerminalInputRelay(
      continuation: input.continuation,
      dropContinuation: inputDrops.continuation
    )
    self.inputRelay = inputRelay
    surfaceView = GhosttyRemoteSurfaceView(
      runtime: runtime,
      inputRelay: inputRelay,
      localization: localization
    )
    surfaceView.onGeometryChanged = { [weak self] geometry in
      self?.resize(geometry)
    }
  }

  func attach() {
    guard !didStart, !isShuttingDown else { return }
    didStart = true
    errorMessage = ""
    beginInputOverloadReporting()
    beginInputDelivery()
    attachTask = Task { [weak self] in
      guard let self else { return }
      do {
        let handle = try await service.attachTerminal(id: terminalID)
        guard !isShuttingDown else {
          await handle.shutdown()
          return
        }
        self.handle = handle
        isAttached = true
        if let latestGeometry {
          _ = await handle.resize(cols: latestGeometry.cols, rows: latestGeometry.rows)
        }
        guard !isShuttingDown else {
          self.handle = nil
          isAttached = false
          await handle.shutdown()
          return
        }
        beginUpdates(from: handle)
        requestRenderDrain(from: handle)
      } catch {
        if !isShuttingDown { didStart = false }
        errorMessage = localization.text(
          "error.terminal_attach",
          "The terminal could not be attached."
        )
      }
      attachTask = nil
    }
  }

  private func beginInputOverloadReporting() {
    guard inputDropTask == nil else { return }
    let stream = inputDropStream
    inputDropTask = Task { [weak self] in
      for await _ in stream {
        guard !Task.isCancelled, let self, !isShuttingDown else { return }
        reportInputOverload()
      }
    }
  }

  private func beginInputDelivery() {
    guard inputTask == nil else { return }
    let stream = inputStream
    inputTask = Task { [weak self] in
      for await queuedInput in stream {
        guard !Task.isCancelled, let self, !isShuttingDown else { return }
        guard let handle, isAttached else { continue }
        let accepted = await handle.submit(
          queuedInput.input,
          inputEpoch: queuedInput.epoch
        )
        guard !Task.isCancelled, !isShuttingDown,
          let activeHandle = self.handle, activeHandle === handle
        else { continue }
        let rejected = localization.text(
          "error.terminal_input_rejected",
          "Terminal input was rejected."
        )
        if !accepted {
          inputErrorMessage = rejected
          errorMessage = rejected
        } else if let inputErrorMessage {
          self.inputErrorMessage = nil
          if errorMessage == inputErrorMessage { errorMessage = "" }
        }
      }
    }
  }

  private func beginUpdates(from handle: TerminalHandle) {
    updateTask?.cancel()
    updateTask = Task { [weak self] in
      let updates = await handle.updates()
      for await _ in updates.stream {
        guard !Task.isCancelled else { break }
        guard let self else { continue }
        requestRenderDrain(from: handle)
      }
      await handle.stopUpdates(generation: updates.generation)
    }
  }

  private func requestRenderDrain(from handle: TerminalHandle) {
    drainRequested = true
    guard drainTask == nil else { return }
    drainTask = Task { [weak self, weak handle] in
      guard let self, let handle else { return }
      defer {
        let shouldContinue = drainRequested && !isShuttingDown && !Task.isCancelled
        drainTask = nil
        if shouldContinue { requestRenderDrain(from: handle) }
      }
      for _ in 0..<Self.maxRenderBatchesPerPass {
        guard !Task.isCancelled, !isShuttingDown else { return }
        drainRequested = false
        let batch = await handle.drainRenderEvents()
        guard !Task.isCancelled, !isShuttingDown else { return }
        if batch.overflowed {
          await failAttachment(
            handle,
            message: localization.text(
              "error.terminal_render_limit",
              "Terminal output exceeded the safe display limit. Select Retry."
            )
          )
          return
        }
        for event in batch.events {
          guard !Task.isCancelled, !isShuttingDown else { return }
          surfaceView.apply(event)
          await Task.yield()
        }
        if let rendererError = surfaceView.initializationError {
          await failAttachment(handle, message: rendererError)
          return
        }
        let nextDidExit = await handle.hasExited()
        if didExit != nextDidExit { didExit = nextDidExit }
        let connectionClosed = await handle.isClosed()
        if terminalAttachmentDisposition(
          didExit: nextDidExit,
          connectionClosed: connectionClosed
        ) == .reconnectRequired {
          await failAttachment(
            handle,
            message: localization.text(
              "error.terminal_connection_stopped",
              "The terminal connection stopped. Select Retry."
            )
          )
          return
        }
        guard !Task.isCancelled, !isShuttingDown else { return }
        if batch.hasMore { drainRequested = true }
        if !drainRequested { return }
      }
    }
  }

  private func failAttachment(_ handle: TerminalHandle, message: String) async {
    let workers = [updateTask, resizeTask].compactMap { $0 }
    for worker in workers { worker.cancel() }
    updateTask = nil
    resizeTask = nil
    drainRequested = false
    self.handle = nil
    isAttached = false
    didStart = false
    didExit = false
    inputErrorMessage = nil
    resizeQueue = NewestResizeQueue()
    errorMessage = ""
    await handle.shutdown()
    for worker in workers { await worker.value }
    errorMessage = message
  }

  func submit(_ input: TerminalInput) {
    guard isAttached, !didExit else { return }
    inputRelay.send(input)
  }

  private func reportInputOverload() {
    let message = localization.text(
      "error.terminal_input_overloaded",
      "Terminal input is busy; try again."
    )
    inputErrorMessage = message
    errorMessage = message
  }

  func resize(_ geometry: TerminalGeometry) {
    guard geometry != latestGeometry else { return }
    latestGeometry = geometry
    guard let handle, isAttached else { return }
    let shouldStart = resizeQueue.submit(geometry)
    guard shouldStart, resizeTask == nil else { return }
    resizeTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, let next = resizeQueue.take() {
        let accepted = await handle.resize(cols: next.cols, rows: next.rows)
        guard !Task.isCancelled else { return }
        if !accepted, resizeQueue.pending == nil, !isShuttingDown {
          errorMessage = localization.text(
            "error.terminal_resize_rejected",
            "Terminal resize was rejected."
          )
        }
      }
      resizeTask = nil
    }
  }

  func shutdown() {
    Task { await shutdownAndWait() }
  }

  func shutdownAndWait() async {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    let pendingAttach = attachTask
    let pendingResize = resizeTask
    let pendingUpdates = updateTask
    let pendingInput = inputTask
    let pendingInputDrops = inputDropTask
    let pendingDrain = drainTask
    pendingAttach?.cancel()
    pendingResize?.cancel()
    _ = resizeQueue.take()
    pendingUpdates?.cancel()
    pendingInput?.cancel()
    pendingInputDrops?.cancel()
    pendingDrain?.cancel()
    drainRequested = false
    inputContinuation.finish()
    inputDropContinuation.finish()
    _ = await pendingAttach?.value
    _ = await pendingResize?.value
    _ = await pendingUpdates?.value
    _ = await pendingInput?.value
    _ = await pendingInputDrops?.value
    _ = await pendingDrain?.value
    attachTask = nil
    resizeTask = nil
    updateTask = nil
    inputTask = nil
    inputDropTask = nil
    drainTask = nil
    let owned = handle
    handle = nil
    isAttached = false
    await owned?.shutdown()
  }
}
