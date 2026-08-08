import Foundation
import Observation

enum TerminalInput: Sendable {
  case bytes(Data)
  case paste(String)
  case key(chord: String, repeat: Bool)
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

@MainActor
@Observable
final class NativeTerminalModel {
  let terminalID: String
  private(set) var diagnostics = ""
  private(set) var errorMessage = ""
  private(set) var isAttached = false
  private(set) var didExit = false

  @ObservationIgnored private let service: FrontendService
  @ObservationIgnored private var handle: TerminalHandle?
  @ObservationIgnored private var updateTask: Task<Void, Never>?
  @ObservationIgnored private var inputTask: Task<Void, Never>?
  @ObservationIgnored private var attachTask: Task<Void, Never>?
  @ObservationIgnored private var resizeTask: Task<Void, Never>?
  @ObservationIgnored private var drainTask: Task<Void, Never>?
  @ObservationIgnored private var inputDropTask: Task<Void, Never>?
  @ObservationIgnored private var drainRequested = false
  @ObservationIgnored private var resizeQueue = NewestResizeQueue()
  @ObservationIgnored private let inputStream: AsyncStream<TerminalInput>
  @ObservationIgnored private let inputContinuation: AsyncStream<TerminalInput>.Continuation
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
      didExit: didExit
    )
  }

  init(
    terminalID: String,
    service: FrontendService,
    runtime: NativeGhosttyRuntime?
  ) {
    self.terminalID = terminalID
    self.service = service
    let input = AsyncStream<TerminalInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
    let inputDrops = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    inputStream = input.stream
    inputContinuation = input.continuation
    inputDropStream = inputDrops.stream
    inputDropContinuation = inputDrops.continuation
    let inputRelay = GhosttyTerminalInputRelay(
      continuation: input.continuation,
      dropContinuation: inputDrops.continuation
    )
    surfaceView = GhosttyRemoteSurfaceView(runtime: runtime, inputRelay: inputRelay)
    surfaceView.onGeometryChanged = { [weak self] geometry in
      self?.resize(geometry)
    }
  }

  func attach() {
    guard !didStart, !isShuttingDown else { return }
    didStart = true
    beginInputOverloadReporting()
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
        beginInputDelivery(to: handle)
        beginUpdates(from: handle)
        requestRenderDrain(from: handle)
      } catch {
        if !isShuttingDown { didStart = false }
        errorMessage = L10n.text(
          "error.terminal_attach",
          "The terminal could not be attached."
        )
      }
      attachTask = nil
    }
  }

  private func beginInputOverloadReporting() {
    inputDropTask?.cancel()
    let stream = inputDropStream
    inputDropTask = Task { [weak self] in
      for await _ in stream {
        guard !Task.isCancelled, let self, !isShuttingDown else { return }
        reportInputOverload()
      }
    }
  }

  private func beginInputDelivery(to handle: TerminalHandle) {
    inputTask?.cancel()
    let stream = inputStream
    inputTask = Task { [weak self] in
      for await input in stream {
        guard !Task.isCancelled else { break }
        let accepted = await handle.submit(input)
        guard let self, !isShuttingDown else { return }
        let rejected = L10n.text(
          "error.terminal_input_rejected",
          "Terminal input was rejected."
        )
        if !accepted {
          errorMessage = rejected
        } else if errorMessage == rejected {
          errorMessage = ""
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
      defer { drainTask = nil }
      while !Task.isCancelled, !isShuttingDown {
        drainRequested = false
        let batch = await handle.drainRenderEvents()
        guard !Task.isCancelled, !isShuttingDown else { return }
        for event in batch.events { surfaceView.apply(event) }
        if let rendererError = surfaceView.initializationError {
          errorMessage = rendererError
        }
        if let next = await handle.snapshot() {
          guard !Task.isCancelled, !isShuttingDown else { return }
          diagnostics = next.diagnostics
          didExit = next.didExit
        }
        if batch.hasMore {
          await Task.yield()
          continue
        }
        if !drainRequested { return }
      }
    }
  }

  func submit(_ input: TerminalInput) {
    guard isAttached, !didExit else { return }
    if case .dropped = inputContinuation.yield(input) {
      reportInputOverload()
    }
  }

  private func reportInputOverload() {
    errorMessage = L10n.text(
      "error.terminal_input_overloaded",
      "Terminal input is busy; try again."
    )
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
          errorMessage = L10n.text(
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
