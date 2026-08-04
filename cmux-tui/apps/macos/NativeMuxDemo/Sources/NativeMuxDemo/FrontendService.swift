import CCmuxTerminal
import Foundation

enum FrontendServiceError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      if let data = message.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let readable = object["message"] as? String
      {
        return readable
      }
      return message
    }
  }
}

struct FrontendUpdateSubscription: Sendable {
  let generation: UInt64
  let stream: AsyncStream<Void>
}

typealias FrontendUpdateCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

private final class FrontendUpdateSink: @unchecked Sendable {
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

private func decodeError(_ buffer: [CChar]) -> String {
  String(
    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
    as: UTF8.self
  )
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
  private var raw: OpaquePointer?
  private var updateSink: FrontendUpdateSink?
  private var updateGeneration: UInt64 = 0

  private init(rawAddress: UInt) {
    raw = OpaquePointer(bitPattern: rawAddress)
  }

  static func connect(invitation: String) async throws -> FrontendService {
    let result = await Task.detached(priority: .userInitiated) {
      var error = [CChar](repeating: 0, count: 2_048)
      let handle = invitation.withCString {
        cmux_frontend_client_connect_with_timeout($0, &error, error.count, 20_000)
      }
      return ConnectedFrontend(
        rawAddress: handle.map { UInt(bitPattern: $0) },
        error: decodeError(error)
      )
    }.value
    guard let rawAddress = result.rawAddress else {
      throw FrontendServiceError.message(result.error)
    }
    return FrontendService(rawAddress: rawAddress)
  }

  func request<T: Decodable & Sendable>(
    _ operation: String,
    params: [String: JSONValue],
    mutation: Bool = false,
    as type: T.Type = T.self
  ) throws -> T {
    guard let raw else {
      throw FrontendServiceError.message(
        L10n.text("error.connection_closed", "The frontend connection is closed.")
      )
    }
    let paramsJSON = try params.encodedJSON()
    var error = [CChar](repeating: 0, count: 4_096)
    let result = operation.withCString { operationPointer in
      paramsJSON.withCString { paramsPointer in
        cmux_frontend_client_request(
          raw,
          operationPointer,
          paramsPointer,
          mutation,
          &error,
          error.count
        )
      }
    }
    guard let result else {
      throw FrontendServiceError.message(decodeError(error))
    }
    defer { cmux_frontend_string_free(result) }
    let data = Data(String(cString: result).utf8)
    return try JSONDecoder().decode(type, from: data)
  }

  func requestDiscardingResult(
    _ operation: String,
    params: [String: JSONValue],
    mutation: Bool = false
  ) throws {
    let _: JSONValueResult = try request(
      operation,
      params: params,
      mutation: mutation,
      as: JSONValueResult.self
    )
  }

  func attachTerminal(id: String) throws -> TerminalHandle {
    guard let raw else {
      throw FrontendServiceError.message(
        L10n.text("error.connection_closed", "The frontend connection is closed.")
      )
    }
    var error = [CChar](repeating: 0, count: 2_048)
    let terminal = id.withCString {
      cmux_frontend_client_attach_terminal(raw, $0, &error, error.count, 15_000)
    }
    guard let terminal else {
      throw FrontendServiceError.message(decodeError(error))
    }
    return TerminalHandle(rawAddress: UInt(bitPattern: terminal))
  }

  func updates() -> FrontendUpdateSubscription {
    stopUpdates()
    updateGeneration &+= 1
    let generation = updateGeneration
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    guard let raw else {
      pair.continuation.finish()
      return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
    }
    let sink = FrontendUpdateSink(pair.continuation)
    updateSink = sink
    cmux_frontend_client_set_update_callback(
      raw,
      frontendUpdateCallback,
      Unmanaged.passUnretained(sink).toOpaque()
    )
    return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
  }

  func stopUpdates(generation: UInt64? = nil) {
    if let generation, generation != updateGeneration { return }
    guard let sink = updateSink else { return }
    if let raw {
      cmux_frontend_client_set_update_callback(raw, nil, nil)
    }
    sink.continuation.finish()
    updateSink = nil
    updateGeneration &+= 1
  }

  func diagnostics() -> String {
    guard let raw else { return "" }
    return copyFrontendCString { cmux_frontend_client_copy_diagnostics(raw, $0, $1) }
  }

  func shutdown() {
    stopUpdates()
    guard let raw else { return }
    self.raw = nil
    cmux_frontend_client_disconnect(raw)
  }
}

// Mutation results are deliberately opaque to the demo. Topology is always
// refreshed from session.snapshot after the mutation commits.
private struct JSONValueResult: Decodable, Sendable {}

actor TerminalHandle {
  private var raw: OpaquePointer?
  private var updateSink: FrontendUpdateSink?
  private var updateGeneration: UInt64 = 0

  init(rawAddress: UInt) {
    raw = OpaquePointer(bitPattern: rawAddress)
  }

  func submit(_ input: TerminalInput) -> Bool {
    guard let raw else { return false }
    switch input {
    case .bytes(let data):
      return data.withUnsafeBytes {
        cmux_frontend_terminal_send(
          raw,
          $0.bindMemory(to: UInt8.self).baseAddress,
          $0.count
        )
      }
    case .paste(let text):
      let data = Data(text.utf8)
      return data.withUnsafeBytes {
        cmux_frontend_terminal_paste(
          raw,
          $0.bindMemory(to: UInt8.self).baseAddress,
          $0.count
        )
      }
    case .key(let chord, let isRepeat):
      return chord.withCString { cmux_frontend_terminal_send_key(raw, $0, isRepeat) }
    }
  }

  func resize(cols: UInt16, rows: UInt16) -> Bool {
    guard let raw else { return false }
    return cmux_frontend_terminal_resize(raw, cols, rows)
  }

  func updates() -> FrontendUpdateSubscription {
    stopUpdates()
    updateGeneration &+= 1
    let generation = updateGeneration
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    guard let raw else {
      pair.continuation.finish()
      return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
    }
    let sink = FrontendUpdateSink(pair.continuation)
    updateSink = sink
    cmux_frontend_terminal_set_update_callback(
      raw,
      frontendUpdateCallback,
      Unmanaged.passUnretained(sink).toOpaque()
    )
    return FrontendUpdateSubscription(generation: generation, stream: pair.stream)
  }

  func snapshot() -> TerminalRenderSnapshot? {
    guard let raw else { return nil }
    return TerminalRenderSnapshot(
      diagnostics: copyFrontendCString {
        cmux_frontend_terminal_copy_diagnostics(raw, $0, $1)
      },
      didExit: cmux_frontend_terminal_has_exited(raw)
    )
  }

  func drainRenderEvents() -> [TerminalRenderEvent] {
    guard let raw else { return [] }
    var result: [TerminalRenderEvent] = []
    while true {
      var descriptor = CmuxFrontendRenderEvent()
      guard cmux_frontend_terminal_copy_next_render_event(raw, &descriptor, nil, 0) else {
        break
      }
      guard let kind = TerminalRenderEvent.Kind(rawValue: descriptor.kind) else {
        // Unknown empty events have already been consumed. A future
        // non-empty event stays queued so an older frontend does not
        // silently discard renderer state it cannot understand.
        if descriptor.payload_length > 0 { break }
        continue
      }
      var payload = Data()
      if descriptor.payload_length > 0 {
        payload = Data(count: descriptor.payload_length)
        let copied = payload.withUnsafeMutableBytes { bytes in
          cmux_frontend_terminal_copy_next_render_event(
            raw,
            &descriptor,
            bytes.bindMemory(to: UInt8.self).baseAddress,
            bytes.count
          )
        }
        guard copied else { break }
      }
      result.append(
        TerminalRenderEvent(
          kind: kind,
          geometry: TerminalGeometry(cols: descriptor.cols, rows: descriptor.rows),
          payload: payload
        ))
    }
    return result
  }

  func stopUpdates(generation: UInt64? = nil) {
    if let generation, generation != updateGeneration { return }
    guard let sink = updateSink else { return }
    if let raw {
      cmux_frontend_terminal_set_update_callback(raw, nil, nil)
    }
    sink.continuation.finish()
    updateSink = nil
    updateGeneration &+= 1
  }

  func shutdown() {
    stopUpdates()
    guard let raw else { return }
    self.raw = nil
    cmux_frontend_terminal_disconnect(raw)
  }
}

struct TerminalRenderSnapshot: Sendable {
  let diagnostics: String
  let didExit: Bool
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
