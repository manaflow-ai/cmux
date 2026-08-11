import CCmuxTerminal
import Foundation
import Dispatch

enum FrontendServiceError: LocalizedError {
  case localized(String)
  case connectionFailure(String, localization: Localization)
  case requestRejected(String, localization: Localization)
  case terminalAttachFailure(String, localization: Localization)
  case terminalAttachQueueFull(localization: Localization)
  case mutationIndeterminate(
    operation: String,
    idempotencyKey: String,
    localization: Localization
  )

  static func requestFailure(
    _ message: String,
    localization: Localization
  ) -> FrontendServiceError {
    guard let data = message.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["code"] as? String == "mutation.indeterminate",
      let details = object["details"] as? [String: Any],
      let operation = details["operation"] as? String,
      let idempotencyKey = details["idempotency_key"] as? String
    else {
      return .requestRejected(message, localization: localization)
    }
    return .mutationIndeterminate(
      operation: operation,
      idempotencyKey: idempotencyKey,
      localization: localization
    )
  }

  var requiresAuthoritativeReconciliation: Bool {
    if case .mutationIndeterminate = self { return true }
    return false
  }

  var errorDescription: String? {
    switch self {
    case .localized(let message): return message
    case .connectionFailure(_, let localization):
      return localization.text(
        "error.connection_failure",
        "The frontend could not connect. See diagnostics for details."
      )
    case .requestRejected(_, let localization):
      return localization.text(
        "error.request_failure",
        "The frontend request failed. See diagnostics for details."
      )
    case .terminalAttachFailure(_, let localization):
      return localization.text("error.terminal_attach", "The terminal could not be attached.")
    case .terminalAttachQueueFull(let localization):
      return localization.text(
        "error.terminal_attach_queue_full",
        "Too many terminal attachments are waiting. Try again after they finish."
      )
    case .mutationIndeterminate(_, _, let localization):
      return localization.text(
        "error.mutation_indeterminate",
        "The operation result is not known. The view will refresh."
      )
    }
  }

  var diagnosticDescription: String? {
    switch self {
    case .connectionFailure(let message, _), .requestRejected(let message, _),
      .terminalAttachFailure(let message, _): return message
    case .localized, .terminalAttachQueueFull, .mutationIndeterminate: return nil
    }
  }
}

struct FrontendUpdateSubscription: Sendable {
  let generation: UInt64
  let stream: AsyncStream<Void>
}

typealias FrontendUpdateCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

private final class FrontendUpdateSink: Sendable {
  let continuation: AsyncStream<Void>.Continuation

  init(_ continuation: AsyncStream<Void>.Continuation) {
    self.continuation = continuation
  }
}

private let frontendUpdateCallback: FrontendUpdateCallback = { context in
  guard let context else { return }
  Unmanaged<FrontendUpdateSink>
    .fromOpaque(context)
    .takeUnretainedValue()
    .continuation
    .yield()
}

private struct ConnectedFrontend: Sendable {
  let rawAddress: UInt?
  let error: String
}

private struct DetachedRequestFailure: Error, Sendable {
  let message: String
}

private func decodeError(_ buffer: [CChar]) -> String {
  String(
    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
    as: UTF8.self
  )
}

typealias FFITimeoutScheduler = @Sendable (
  _ nanoseconds: UInt64,
  _ action: @escaping @Sendable () async -> Void
) -> Task<Void, Never>

private func continuousClockFFITimeout(
  nanoseconds: UInt64,
  action: @escaping @Sendable () async -> Void
) -> Task<Void, Never> {
  Task {
    do {
      try await ContinuousClock().sleep(
        for: .nanoseconds(Int64(clamping: nanoseconds))
      )
    } catch {
      return
    }
    await action()
  }
}

// Safe because the queue is the sole executor for each handle's blocking C
// calls; callers never access the raw handle outside this serialized path.
final class SerialFFIExecutor: @unchecked Sendable {
  private let queue: DispatchQueue
  private let timeoutScheduler: FFITimeoutScheduler

  init(
    label: String,
    timeoutScheduler: @escaping FFITimeoutScheduler = continuousClockFFITimeout
  ) {
    queue = DispatchQueue(label: label)
    self.timeoutScheduler = timeoutScheduler
  }

  func run<T: Sendable>(
    _ operation: @escaping @Sendable () -> T,
    onEnqueued: (@Sendable () -> Void)? = nil
  ) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: operation()) }
      onEnqueued?()
    }
  }

  func runCancellable<T: Sendable>(
    cancellation: FFICancellation,
    timeoutNanoseconds: UInt64? = nil,
    _ operation: @escaping @Sendable () -> T,
    onEnqueued: (@Sendable () -> Void)? = nil
  ) async -> T? {
    let waiter = FFIResultWaiter<T>()
    queue.async {
      guard cancellation.beginExecution() else {
        Task { await waiter.complete(nil) }
        return
      }
      let result = operation()
      cancellation.finishExecution()
      Task { await waiter.complete(result) }
    }
    if let timeoutNanoseconds {
      let timeoutTask = timeoutScheduler(timeoutNanoseconds) {
        if cancellation.cancel() { await waiter.complete(nil) }
      }
      await waiter.installTimeoutTask(timeoutTask)
    }
    onEnqueued?()
    return await withTaskCancellationHandler {
      await waiter.value()
    } onCancel: {
      if cancellation.cancel() {
        Task { await waiter.complete(nil) }
      }
    }
  }
}

private actor FFIResultWaiter<T: Sendable> {
  private var continuation: CheckedContinuation<T?, Never>?
  private var completed = false
  private var result: T?
  private var timeoutTask: Task<Void, Never>?

  func value() async -> T? {
    if completed { return result }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func installTimeoutTask(_ task: Task<Void, Never>) {
    if completed {
      task.cancel()
    } else {
      timeoutTask = task
    }
  }

  func complete(_ result: T?) {
    guard !completed else { return }
    completed = true
    self.result = result
    let continuation = continuation
    self.continuation = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    continuation?.resume(returning: result)
  }
}

// Safe because raw points to a Rust-owned atomic state machine. The queue
// block and cancellation handler retain this owner until their calls finish.
final class FFICancellation: @unchecked Sendable {
  private let raw: OpaquePointer
  private let onCancel: @Sendable () -> Void

  init(onCancel: @escaping @Sendable () -> Void) {
    raw = cmux_frontend_queue_cancellation_new()!
    self.onCancel = onCancel
  }

  deinit {
    cmux_frontend_queue_cancellation_free(raw)
  }

  func beginExecution() -> Bool {
    cmux_frontend_queue_cancellation_begin_execution(raw)
  }

  func finishExecution() {
    cmux_frontend_queue_cancellation_finish_execution(raw)
  }

  @discardableResult
  func cancel() -> Bool {
    let result = cmux_frontend_queue_cancellation_cancel(raw)
    guard result != UInt8(CMUX_FRONTEND_QUEUE_CANCEL_NONE) else { return false }
    onCancel()
    return result == UInt8(CMUX_FRONTEND_QUEUE_CANCEL_BEFORE_EXECUTION)
  }
}

// Safe because raw points to a Rust object whose cancellation flag and wakeup
// primitive are thread-safe, and this Swift owner releases it only after use.
final class FrontendAttachCancellation: @unchecked Sendable {
  let raw: OpaquePointer

  init() {
    raw = cmux_frontend_attach_cancellation_new()!
  }

  deinit {
    cmux_frontend_attach_cancellation_free(raw)
  }

  func cancel() {
    cmux_frontend_attach_cancellation_cancel(raw)
  }
}

func copyFrontendCString(
  _ copy: (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
) -> String {
  var capacity = copy(nil, 0) + 1
  while true {
    var buffer = [CChar](repeating: 0, count: max(1, capacity))
    let actual = copy(&buffer, buffer.count)
    if actual < buffer.count {
      return String(
        decoding: buffer.prefix(actual).map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
    }
    capacity = actual + 1
  }
}

actor FrontendService {
  private static let requestTimeoutMilliseconds: UInt64 = 15_000
  private static let requestTimeoutNanoseconds = requestTimeoutMilliseconds * 1_000_000
  private static let maximumPendingAttaches = 8

  private var raw: OpaquePointer?
  private let localization: Localization
  private let controlQueue = SerialFFIExecutor(label: "cmux.native-frontend.control")
  // One attach lane limits blocking handshakes without delaying resource control.
  private let attachQueue = SerialFFIExecutor(label: "cmux.native-frontend.attach")
  private var requestCancellations: [UUID: FFICancellation] = [:]
  private var attachCancellations: [UUID: FFICancellation] = [:]
  private var isShuttingDown = false
  private var updateSink: FrontendUpdateSink?
  private var updateGeneration: UInt64 = 0

  private init(rawAddress: UInt, localization: Localization) {
    raw = OpaquePointer(bitPattern: rawAddress)
    self.localization = localization
  }

  static func transferAttachedTerminal(
    _ address: UInt,
    cancellationRequested: Bool,
    disconnect: @escaping @Sendable (UInt) async -> Void
  ) async throws -> UInt {
    guard cancellationRequested else { return address }
    await disconnect(address)
    throw CancellationError()
  }

  private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
    await controlQueue.run(operation)
  }

  static func connect(
    invitation: String,
    localization: Localization = .fallback
  ) async throws -> FrontendService {
    let cancellation = FrontendAttachCancellation()
    let result = await withTaskCancellationHandler {
      await Task.detached(priority: .userInitiated) {
        var error = [CChar](repeating: 0, count: 2_048)
        let handle = invitation.withCString {
          cmux_frontend_client_connect_cancellable(
            $0,
            &error,
            error.count,
            20_000,
            cancellation.raw
          )
        }
        return ConnectedFrontend(
          rawAddress: handle.map { UInt(bitPattern: $0) },
          error: decodeError(error)
        )
      }.value
    } onCancel: {
      cancellation.cancel()
    }
    guard let rawAddress = result.rawAddress else {
      if Task.isCancelled { throw CancellationError() }
      throw FrontendServiceError.connectionFailure(result.error, localization: localization)
    }
    let service = FrontendService(rawAddress: rawAddress, localization: localization)
    if Task.isCancelled {
      await service.shutdown()
      throw CancellationError()
    }
    return service
  }

  func request<T: Decodable & Sendable>(
    _ operation: String,
    params: [String: JSONValue],
    mutation: Bool = false,
    as type: T.Type = T.self
  ) async throws -> T {
    guard !isShuttingDown,
      let rawAddress = raw.map({ UInt(bitPattern: $0) })
    else {
      throw FrontendServiceError.localized(
        localization.text("error.connection_closed", "The frontend connection is closed.")
      )
    }
    let paramsJSON = try params.encodedJSON()
    let requestCancellation = FrontendAttachCancellation()
    let queueCancellation = FFICancellation(onCancel: requestCancellation.cancel)
    let requestID = UUID()
    requestCancellations[requestID] = queueCancellation
    defer { requestCancellations[requestID] = nil }
    let queuedResponse: Result<String, DetachedRequestFailure>? = await controlQueue.runCancellable(
      cancellation: queueCancellation,
      timeoutNanoseconds: Self.requestTimeoutNanoseconds
    ) {
      var error = [CChar](repeating: 0, count: 4_096)
      let result = operation.withCString { operationPointer in
        paramsJSON.withCString { paramsPointer in
          cmux_frontend_client_request_cancellable(
            OpaquePointer(bitPattern: rawAddress)!,
            operationPointer,
            paramsPointer,
            mutation,
            &error,
            error.count,
            FrontendService.requestTimeoutMilliseconds,
            requestCancellation.raw
          )
        }
      }
      guard let result else { return .failure(DetachedRequestFailure(message: decodeError(error))) }
      defer { cmux_frontend_string_free(result) }
      return .success(String(cString: result))
    }
    guard let response = queuedResponse else { throw CancellationError() }
    try Task.checkCancellation()
    let payload: String
    switch response {
    case .success(let value): payload = value
    case .failure(let error):
      throw FrontendServiceError.requestFailure(error.message, localization: localization)
    }
    let data = Data(payload.utf8)
    return try JSONDecoder().decode(type, from: data)
  }

  func requestDiscardingResult(
    _ operation: String,
    params: [String: JSONValue],
    mutation: Bool = false
  ) async throws {
    let _: JSONValueResult = try await request(
      operation,
      params: params,
      mutation: mutation,
      as: JSONValueResult.self
    )
  }

  func attachTerminal(id: String) async throws -> TerminalHandle {
    guard !isShuttingDown,
      let rawAddress = raw.map({ UInt(bitPattern: $0) })
    else {
      throw FrontendServiceError.localized(
        localization.text("error.connection_closed", "The frontend connection is closed.")
      )
    }
    let attachCancellation = FrontendAttachCancellation()
    let queueCancellation = FFICancellation(onCancel: attachCancellation.cancel)
    guard attachCancellations.count < Self.maximumPendingAttaches else {
      throw FrontendServiceError.terminalAttachQueueFull(localization: localization)
    }
    let attachID = UUID()
    attachCancellations[attachID] = queueCancellation
    defer { attachCancellations[attachID] = nil }
    let queuedResult: Result<UInt, DetachedRequestFailure>? = await attachQueue.runCancellable(
      cancellation: queueCancellation,
      timeoutNanoseconds: Self.requestTimeoutNanoseconds
    ) {
      var error = [CChar](repeating: 0, count: 2_048)
      let terminal = id.withCString {
        cmux_frontend_client_attach_terminal_cancellable(
          OpaquePointer(bitPattern: rawAddress)!,
          $0,
          &error,
          error.count,
          FrontendService.requestTimeoutMilliseconds,
          attachCancellation.raw
        )
      }
      guard let terminal else { return .failure(DetachedRequestFailure(message: decodeError(error))) }
      return .success(UInt(bitPattern: terminal))
    }
    guard let result = queuedResult else { throw CancellationError() }
    switch result {
    case .success(let value):
      let queue = attachQueue
      let address = try await Self.transferAttachedTerminal(
        value,
        cancellationRequested: Task.isCancelled
      ) { address in
        await queue.run {
          cmux_frontend_terminal_disconnect(OpaquePointer(bitPattern: address)!)
        }
      }
      return TerminalHandle(rawAddress: address)
    case .failure(let error):
      try Task.checkCancellation()
      throw FrontendServiceError.terminalAttachFailure(
        error.message,
        localization: localization
      )
    }
  }

  func updates() async -> FrontendUpdateSubscription {
    await stopUpdates()
    updateGeneration &+= 1
    let generation = updateGeneration
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    guard let raw else {
      pair.continuation.finish()
      return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
    }
    let sink = FrontendUpdateSink(pair.continuation)
    updateSink = sink
    let address = UInt(bitPattern: raw)
    await enqueue {
      cmux_frontend_client_set_update_callback(
        OpaquePointer(bitPattern: address),
        frontendUpdateCallback,
        Unmanaged.passUnretained(sink).toOpaque()
      )
    }
    return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
  }

  func drainResourceUpdates() async -> FrontendResourceUpdateBatch {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else {
      return FrontendResourceUpdateBatch(
        envelopes: [], hasMore: false, overflowed: false, ended: true, endReason: .error
      )
    }
    let batch = await enqueue {
      let raw = OpaquePointer(bitPattern: rawAddress)!
      return drainFrontendResourceUpdates(
        discard: { cmux_frontend_client_discard_resource_updates(raw) },
        copy: { descriptor, buffer, capacity in
          cmux_frontend_client_copy_resource_update(raw, &descriptor, buffer, capacity)
        }
      )
    }
    if batch.hasMore { updateSink?.continuation.yield() }
    return batch
  }

  func discardResourceUpdates() async {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else { return }
    await enqueue {
      cmux_frontend_client_discard_resource_updates(OpaquePointer(bitPattern: rawAddress))
    }
  }

  func stopUpdates(generation: UInt64? = nil) async {
    if let generation, generation != updateGeneration { return }
    guard let sink = updateSink else { return }
    if let raw {
      let address = UInt(bitPattern: raw)
      await enqueue { cmux_frontend_client_set_update_callback(OpaquePointer(bitPattern: address), nil, nil) }
    }
    sink.continuation.finish()
    updateSink = nil
    updateGeneration &+= 1
  }

  func diagnostics() async -> String {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else { return "" }
    return await enqueue {
      copyFrontendCString { cmux_frontend_client_copy_diagnostics(OpaquePointer(bitPattern: rawAddress), $0, $1) }
    }
  }

  func shutdown() async {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    for cancellation in requestCancellations.values { cancellation.cancel() }
    for cancellation in attachCancellations.values { cancellation.cancel() }
    await stopUpdates()
    await attachQueue.run {}
    guard let raw else { return }
    self.raw = nil
    let address = UInt(bitPattern: raw)
    await enqueue { cmux_frontend_client_disconnect(OpaquePointer(bitPattern: address)!) }
  }
}

// Mutation results are deliberately opaque to the demo. Topology is always
// refreshed from session.snapshot after the mutation commits.
private struct JSONValueResult: Decodable, Sendable {}

actor TerminalHandle {
  private var raw: OpaquePointer?
  private let ffiQueue = SerialFFIExecutor(label: "cmux.native-terminal.ffi")
  private var updateSink: FrontendUpdateSink?
  private var updateGeneration: UInt64 = 0

  init(rawAddress: UInt) {
    raw = OpaquePointer(bitPattern: rawAddress)
  }

  private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
    await ffiQueue.run(operation)
  }

  func submit(_ input: TerminalInput) async -> Bool {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else { return false }
    return await enqueue {
      let raw = OpaquePointer(bitPattern: rawAddress)!
      switch input {
      case .bytes(let data):
        return data.withUnsafeBytes { cmux_frontend_terminal_send(raw, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
      case .paste(let text):
        let data = Data(text.utf8)
        return data.withUnsafeBytes { cmux_frontend_terminal_paste(raw, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
      case .key(let chord, let isRepeat):
        return chord.withCString { cmux_frontend_terminal_send_key(raw, $0, isRepeat) }
      }
    }
  }

  func resize(cols: UInt16, rows: UInt16) async -> Bool {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else { return false }
    return await enqueue {
      cmux_frontend_terminal_resize(OpaquePointer(bitPattern: rawAddress)!, cols, rows)
    }
  }

  func updates() async -> FrontendUpdateSubscription {
    await stopUpdates()
    updateGeneration &+= 1
    let generation = updateGeneration
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    guard let raw else {
      pair.continuation.finish()
      return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
    }
    let sink = FrontendUpdateSink(pair.continuation)
    updateSink = sink
    let address = UInt(bitPattern: raw)
    await enqueue {
      cmux_frontend_terminal_set_update_callback(
        OpaquePointer(bitPattern: address),
        frontendUpdateCallback,
        Unmanaged.passUnretained(sink).toOpaque()
      )
    }
    return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
  }

  func hasExited() async -> Bool {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else { return true }
    return await enqueue {
      cmux_frontend_terminal_has_exited(OpaquePointer(bitPattern: rawAddress))
    }
  }

  func isClosed() async -> Bool {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else { return true }
    return await enqueue {
      cmux_frontend_terminal_is_closed(OpaquePointer(bitPattern: rawAddress))
    }
  }

  func drainRenderEvents() async -> TerminalRenderEventBatch {
    guard let rawAddress = raw.map({ UInt(bitPattern: $0) }) else {
      return TerminalRenderEventBatch(events: [], hasMore: false, overflowed: false)
    }
    return await enqueue {
      let raw = OpaquePointer(bitPattern: rawAddress)!
      return drainTerminalRenderEvents(
        discard: { cmux_frontend_terminal_discard_render_events(raw) },
        copy: { descriptor, buffer, capacity in
          cmux_frontend_terminal_copy_next_render_event(raw, &descriptor, buffer, capacity)
        }
      )
    }
  }

  func stopUpdates(generation: UInt64? = nil) async {
    if let generation, generation != updateGeneration { return }
    guard let sink = updateSink else { return }
    if let raw {
      let address = UInt(bitPattern: raw)
      await enqueue { cmux_frontend_terminal_set_update_callback(OpaquePointer(bitPattern: address), nil, nil) }
    }
    sink.continuation.finish()
    updateSink = nil
    updateGeneration &+= 1
  }

  func shutdown() async {
    await stopUpdates()
    guard let raw else { return }
    self.raw = nil
    let address = UInt(bitPattern: raw)
    await enqueue { cmux_frontend_terminal_disconnect(OpaquePointer(bitPattern: address)!) }
  }
}

struct TerminalRenderEvent: Sendable {
  enum Kind: UInt32, Sendable {
    case reset = 1
    case bytes = 2
    case resize = 3
    case ready = 4
    case exit = 5
  }

  let kind: Kind
  let geometry: TerminalGeometry
  let payload: Data
}

struct TerminalRenderEventBatch: Sendable {
  let events: [TerminalRenderEvent]
  let hasMore: Bool
  let overflowed: Bool
}

func drainTerminalRenderEvents(
  maximumEvents: Int = 16,
  maximumEventBytes: Int = Int(CMUX_TERMINAL_CLIENT_COPY_MAX_BYTES),
  maximumBytesEventBytes: Int = 65_536,
  maximumBytes: Int = 262_144,
  discard: () -> Void = {},
  copy: (
    _ descriptor: inout CmuxFrontendRenderEvent,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int
  ) -> Bool
) -> TerminalRenderEventBatch {
  let eventBudget = max(1, maximumEvents)
  let eventByteBudget = max(1, maximumEventBytes)
  let bytesEventByteBudget = max(1, min(eventByteBudget, maximumBytesEventBytes))
  let byteBudget = max(1, maximumBytes)
  var processed = 0
  var retainedBytes = 0
  var result: [TerminalRenderEvent] = []
  result.reserveCapacity(eventBudget)
  while processed < eventBudget {
    var descriptor = CmuxFrontendRenderEvent()
    guard copy(&descriptor, nil, 0) else { break }
    let kind = TerminalRenderEvent.Kind(rawValue: descriptor.kind)
    let payloadByteBudget = descriptor.kind == TerminalRenderEvent.Kind.reset.rawValue
      ? eventByteBudget
      : bytesEventByteBudget
    if descriptor.payload_length > payloadByteBudget {
      discard()
      return TerminalRenderEventBatch(events: [], hasMore: false, overflowed: true)
    }
    if retainedBytes > 0,
      descriptor.payload_length > byteBudget - min(retainedBytes, byteBudget)
    {
      return TerminalRenderEventBatch(events: result, hasMore: true, overflowed: false)
    }
    var payload = Data()
    if descriptor.payload_length > 0 {
      payload = Data(count: descriptor.payload_length)
      let copied = payload.withUnsafeMutableBytes { bytes in
        copy(
          &descriptor,
          bytes.bindMemory(to: UInt8.self).baseAddress,
          bytes.count
        )
      }
      guard copied else { break }
    }
    processed += 1
    retainedBytes += payload.count
    guard let kind else { continue }
    result.append(TerminalRenderEvent(
      kind: kind,
      geometry: TerminalGeometry(cols: descriptor.cols, rows: descriptor.rows),
      payload: payload
    ))
  }
  return TerminalRenderEventBatch(
    events: result,
    hasMore: processed >= eventBudget,
    overflowed: false
  )
}
