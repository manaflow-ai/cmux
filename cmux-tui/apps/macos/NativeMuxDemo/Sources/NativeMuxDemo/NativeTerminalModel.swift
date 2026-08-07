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
  @ObservationIgnored private var resizeQueue = NewestResizeQueue()
  @ObservationIgnored private let inputStream: AsyncStream<TerminalInput>
  @ObservationIgnored private let inputContinuation: AsyncStream<TerminalInput>.Continuation
  @ObservationIgnored private var latestGeometry: TerminalGeometry?
  @ObservationIgnored private var didStart = false
  @ObservationIgnored private var isShuttingDown = false
  @ObservationIgnored let surfaceView: GhosttyRemoteSurfaceView

  init(
    terminalID: String,
    service: FrontendService,
    runtime: NativeGhosttyRuntime?
  ) {
    self.terminalID = terminalID
    self.service = service
    let input = AsyncStream<TerminalInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
    inputStream = input.stream
    inputContinuation = input.continuation
    let inputRelay = GhosttyTerminalInputRelay(continuation: input.continuation)
    surfaceView = GhosttyRemoteSurfaceView(runtime: runtime, inputRelay: inputRelay)
    surfaceView.onGeometryChanged = { [weak self] geometry in
      self?.resize(geometry)
    }
  }

  func attach() {
    guard !didStart, !isShuttingDown else { return }
    didStart = true
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
        beginInputDelivery(to: handle)
        beginUpdates(from: handle)
        await consumeUpdates(from: handle)
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
        await consumeUpdates(from: handle)
      }
      await handle.stopUpdates(generation: updates.generation)
    }
  }

  private func consumeUpdates(from handle: TerminalHandle) async {
    let events = await handle.drainRenderEvents()
    for event in events {
      surfaceView.apply(event)
    }
    if let rendererError = surfaceView.initializationError {
      errorMessage = rendererError
    }
    if let next = await handle.snapshot() {
      diagnostics = next.diagnostics
      didExit = next.didExit
    }
  }

  func submit(_ input: TerminalInput) {
    guard isAttached, !didExit else { return }
    inputContinuation.yield(input)
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
    attachTask?.cancel()
    resizeTask?.cancel()
    _ = resizeQueue.take()
    updateTask?.cancel()
    inputTask?.cancel()
    inputContinuation.finish()
    let owned = handle
    handle = nil
    isAttached = false
    await owned?.shutdown()
  }
}
