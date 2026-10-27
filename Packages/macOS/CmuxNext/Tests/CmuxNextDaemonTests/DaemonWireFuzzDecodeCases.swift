import CmuxFuzzSupport
import CmuxNextIPC
import Foundation
@testable import CmuxNextDaemon

/// ``DaemonEvent/decode(name:line:)``: a well-formed event is its case, a field of the wrong type makes it
/// `.unknown` with the line's payload, and any line under any name gives an event.
enum WireFuzzEventCase {
    /// One event line and the event it decodes to.
    struct Sample {
        var name: String
        var line: Data
        var expected: DaemonEvent

        static func random(_ rng: inout FuzzRNG) throws -> Sample {
            let rawSurface = UInt64(rng.below(1 << 20))
            let surface = SurfaceID(rawValue: rawSurface)
            // A field of the wrong type: the event's decoder throws and the line arrives as `.unknown`.
            let confused = rng.oneIn(5)
            var object: [String: Any] = rng.oneIn(3) ? WireFuzzJSON.object(&rng) : [:]
            let name: String
            var expected: DaemonEvent?
            switch rng.below(11) {
            case 0:
                name = "title-changed"
                object["surface"] = confused ? "s" as Any : Int(rawSurface)
                let title: String? = rng.oneIn(4) ? nil : rng.text(WireFuzzJSON.text, 24)
                if let title { object["title"] = title }
                expected = .titleChanged(surface: surface, title: title ?? "")
            case 1:
                name = "surface-resized"
                let cols = rng.int(in: -2...500)
                let rows = rng.int(in: -2...200)
                object["surface"] = Int(rawSurface)
                object["cols"] = confused ? "wide" as Any : cols
                object["rows"] = rows
                expected = .surfaceResized(surface: surface, size: CellSize(cols: cols, rows: rows))
            case 2:
                name = "scroll-changed"
                let offset = UInt64(rng.below(1 << 30)) << UInt64(rng.below(10))
                let atBottom = rng.bool()
                object["surface"] = Int(rawSurface)
                object["offset"] = Int(offset)
                object["at_bottom"] = confused ? "yes" as Any : atBottom
                expected = .scrollChanged(surface: surface, offset: offset, atBottom: atBottom)
            case 3:
                name = "bell"
                object["surface"] = confused ? -1 : Int(rawSurface)
                expected = .bell(surface: surface)
            case 4:
                name = "surface-exited"
                object["surface"] = confused ? NSNull() as Any : Int(rawSurface)
                expected = .surfaceExited(surface: surface)
            case 5:
                name = "tree-changed"
                var transaction: ClientTransactionID?
                switch rng.below(3) {
                case 0:
                    break
                case 1:
                    let text = rng.text(WireFuzzJSON.text, 12)
                    object["transaction"] = text
                    transaction = ClientTransactionID(rawValue: text)
                default:
                    let number = rng.below(1 << 30)
                    object["transaction"] = number
                    transaction = ClientTransactionID(rawValue: String(number))
                }
                if confused { object["transaction"] = true }
                expected = .treeChanged(transaction: transaction)
            case 6:
                name = "keybindings-changed"
                let revision = UInt64(rng.below(1 << 30))
                object["revision"] = confused ? "r" as Any : Int(revision)
                expected = .keybindingsChanged(revision: revision)
            case 7:
                name = "overflow"
                let error: String? = rng.oneIn(3) ? nil : rng.text(WireFuzzJSON.text, 16)
                if confused {
                    object["error"] = 5
                } else if let error {
                    object["error"] = error
                }
                expected = .overflow(error ?? "overflow")
            case 8:
                // Its payload is never read.
                name = "daemon-shutdown"
                expected = .daemonShutdown
            case 9:
                name = "personal-changed"
                expected = .personalChanged
            default:
                name = "fuzz-" + rng.text(WireFuzzJSON.keys, 8)
            }
            object["event"] = name
            let line = Data(try WireFuzzJSON.bytes(object))
            let payload = try JSONDecoder().decode(JSONValue.self, from: line)
            let readsNoPayload = name == "daemon-shutdown" || name == "personal-changed"
            if expected == nil || (confused && !readsNoPayload) {
                expected = .unknown(name: name, payload: payload)
            }
            return Sample(name: name, line: line, expected: try WireFuzzJSON.required(expected, "no expected event"))
        }
    }

    /// Names a mutated line is decoded under besides its own: decoders that read other fields.
    static let otherNames = ["layout-changed", "tab-added", "agent-changed", "notification", "history-changed",
                             "terminal-clipboard-read", "pairing-requested", LineTransport.streamEvent]

    static func check(_ sample: Sample, _ rng: inout FuzzRNG) throws {
        let decoded = DaemonEvent.decode(name: sample.name, line: sample.line)
        try FuzzRun.check(decoded == sample.expected,
                          "\(sample.name) decoded as \(decoded), want \(sample.expected): \(String(decoding: sample.line, as: UTF8.self))")
        touch(decoded)
        let mutated = FuzzMutator(dictionary: WireFuzzJSON.tokens).mutate(sample.line, using: &rng)
        let name = rng.oneIn(3) ? otherNames[rng.below(otherNames.count)] : sample.name
        try checkAny(name: name, line: mutated)
    }

    /// Any line under any name gives an event. An `.unknown` one keeps the name, and its payload is the
    /// line as JSON or `.null`; the pairing and stream names build their own payloads.
    static func checkAny(name: String, line: Data) throws {
        let event = DaemonEvent.decode(name: name, line: line)
        touch(event)
        guard case .unknown(let unknownName, let payload) = event else { return }
        try FuzzRun.check(unknownName == name, "\(name) came back as unknown \(unknownName)")
        guard !name.hasPrefix("pairing-"), name != LineTransport.streamEvent else { return }
        let expected = (try? JSONDecoder().decode(JSONValue.self, from: line)) ?? .null
        try FuzzRun.check(payload == expected, "\(name): the unknown event's payload is not the line")
    }

    /// The store reads these of every event it buffers.
    static func touch(_ event: DaemonEvent) {
        _ = event.clientTransactionID
        _ = event.outlivesSnapshot
        _ = CoalesceKey(event)
    }
}

/// ``WireCoding/decodeResponse(_:from:decoder:)``: a reply decodes to its value, and a damaged reply is a
/// `DaemonError.malformedResponse`, never another error.
enum WireFuzzReplyCase {
    static func check(_ rng: inout FuzzRNG) throws {
        var reply: [String: Any] = ["id": 1 + rng.below(9), "ok": true]
        switch rng.below(3) {
        case 0:
            let app = rng.oneIn(4) ? rng.text(WireFuzzJSON.text, 10) : "cmux-tui"
            let version = rng.int(in: 0...40)
            let generation = rng.text(WireFuzzJSON.text, 12)
            let capabilities = (0..<rng.below(5)).map { _ in rng.text(WireFuzzJSON.keys, 8) }
            let pid = rng.int(in: 0...Int(Int32.max))
            var data = WireFuzzJSON.object(&rng)
            data["app"] = app
            data["protocol"] = version
            data["generation"] = generation
            data["capabilities"] = capabilities
            data["pid"] = pid
            reply["data"] = data
            let line = Data(try WireFuzzJSON.bytes(reply))
            let identity = try WireCoding.decodeResponse(DaemonIdentity.self, from: line)
            try FuzzRun.check(identity.app == app && identity.protocolVersion == version && identity.generation.rawValue == generation
                && identity.capabilities == capabilities && identity.pid == Int32(pid), "identify reply misread: \(identity)")
            try checkDamaged(mutate(line, &rng), as: DaemonIdentity.self)
        case 1:
            if rng.bool() { reply["data"] = WireFuzzJSON.object(&rng) }
            let line = Data(try WireFuzzJSON.bytes(reply))
            try FuzzRun.check(try WireCoding.decodeResponse(EmptyResponse.self, from: line) == EmptyResponse(), "an ack did not decode")
            try checkDamaged(mutate(line, &rng), as: EmptyResponse.self)
        default:
            let names = ["working", "blocked", "idle", "done", "unknown", "zzz"]
            var surfaces: [SurfaceID] = []
            var states: [AgentState] = []
            var agents: [[String: Any]] = []
            for _ in 0..<rng.below(5) {
                let surface = rng.below(1 << 20)
                let state = names[rng.below(names.count)]
                surfaces.append(SurfaceID(rawValue: UInt64(surface)))
                states.append(AgentState(rawValue: state) ?? .unknown)
                agents.append(["surface": surface, "state": state, "updated_at_ms": rng.below(1 << 30)] as [String: Any])
            }
            reply["data"] = ["agents": agents] as [String: Any]
            let line = Data(try WireFuzzJSON.bytes(reply))
            let response = try WireCoding.decodeResponse(ListAgentsRequest.Response.self, from: line)
            try FuzzRun.check(response.agents.map(\.surface) == surfaces, "list-agents reply misread its surfaces")
            try FuzzRun.check(response.agents.map(\.state) == states, "list-agents reply misread its states")
            try checkDamaged(mutate(line, &rng), as: ListAgentsRequest.Response.self)
        }
    }

    static func mutate(_ line: Data, _ rng: inout FuzzRNG) -> Data {
        FuzzMutator(dictionary: WireFuzzJSON.tokens).mutate(line, using: &rng)
    }

    /// A value, or `DaemonError.malformedResponse`.
    static func checkDamaged<R: Decodable>(_ line: Data, as type: R.Type) throws {
        do {
            _ = try WireCoding.decodeResponse(type, from: line)
        } catch let error as DaemonError {
            guard case .malformedResponse = error else {
                throw FuzzError.property("\(R.self): \(error) is not malformedResponse", location: "WireFuzzReplyCase")
            }
        } catch {
            throw FuzzError.property("\(R.self): untyped error \(error)", location: "WireFuzzReplyCase")
        }
    }
}

/// Raw bytes through every decoder the reader and the store run on one line.
enum WireFuzzRawLineCase {
    static let seeds: [Data] = [
        #"{"id":3,"ok":true,"data":{"app":"cmux-tui","protocol":12,"generation":"g1","capabilities":["a"],"pid":7}}"#,
        #"{"id":"4","ok":false,"error":{"code":"E_BUSY","message":"busy","retryable":true}}"#,
        #"{"ok":false,"error":"bad request","error_code":"bad_request","reason":"r"}"#,
        #"{"event":"title-changed","surface":4,"title":"~/src"}"#,
        #"{"event":"layout-changed","screen":2,"layout":{"columns":[]},"transaction":"tx1"}"#,
        #"{"event":"agent-changed","surface":1,"state":"working","updated_at_ms":5}"#,
        #"{"event":"pairing-requested","request":18446744073709551615}"#,
        #"{"type":"stream_item","stream_id":"7","item":{"kind":"x"}}"#,
        #"{"id":9,"ok":true,"data":{"agents":[{"surface":1,"state":"idle","updated_at_ms":2}]}}"#,
        "#not json",
    ].map { Data($0.utf8) }

    static let eventNames = ["title-changed", "surface-resized", "scroll-changed", "tree-changed", "layout-changed", "tab-added",
                             "workspace-changed", "agent-changed", "agent-presence-changed", "notification", "history-changed",
                             "bookmarks-changed", "pairing-requested", "overflow", "daemon-shutdown", "personal-changed",
                             "terminal-clipboard-read", LineTransport.streamEvent, "fuzz-unknown"]

    static func check(_ line: Data) throws {
        _ = try? WireCoding.decoder().decode(LineTransport.Envelope.self, from: line)
        try WireFuzzEnvelopeCase.checkScanAgrees(line)
        for name in eventNames {
            try WireFuzzEventCase.checkAny(name: name, line: line)
        }
        try WireFuzzReplyCase.checkDamaged(line, as: DaemonIdentity.self)
        try WireFuzzReplyCase.checkDamaged(line, as: EmptyResponse.self)
        try WireFuzzReplyCase.checkDamaged(line, as: ListAgentsRequest.Response.self)
        // The transport's reader on the raw bytes: messages or one typed refusal, never a trap.
        var reader = FrameReader(limits: FrameReader.Limits(maxLine: LineTransport.maxLineBytes))
        // SAFETY: push copies the bytes out of the storage the closure lends for the call.
        unsafe line.withUnsafeBytes { unsafe reader.push($0) }
        reader.markEndOfStream()
        while (try? reader.next()) != nil {}
    }
}
