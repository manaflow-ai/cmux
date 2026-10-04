public import Foundation
import CmuxNextBrowser
import CmuxNextBrowserAutomation

/// Why a provider frame could not be encoded or decoded.
public nonisolated enum ProviderCodecError: Error, Hashable, Sendable {
    case tooLarge(Int)
    case notJSON
    case missing(field: String, in: String)
}

/// The provider framing (plans/cmux-next/browser-host.md, "Provider
/// connection"): a big-endian u32 byte length, then that many bytes of UTF-8
/// JSON tagged by `t`, at most 64 MiB, in both directions.
public nonisolated struct ProviderCodec {
    public nonisolated init() {}
    public static let version: UInt32 = 1
    public static let maxFrameBytes = 64 << 20
    /// The host reads `hello` with this smaller limit (`MAX_HELLO_BYTES`).
    public static let maxHelloBytes = 1 << 20

    /// One frame with its length prefix.
    public static func encode(_ frame: ProviderFrame) throws(ProviderCodecError) -> Data {
        let object = jsonObject(frame)
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            throw .notJSON
        }
        guard body.count <= maxFrameBytes else { throw .tooLarge(body.count) }
        var out = Data(capacity: body.count + 4)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// The frame's JSON object (no length prefix).
    public static func jsonObject(_ frame: ProviderFrame) -> [String: Any] {
        var o: [String: Any] = ["t": frame.tag]
        switch frame {
        case .hello(let version, let providerID, let installID, let secret, let engines, let tabs):
            o["version"] = NSNumber(value: version)
            o["provider_id"] = providerID
            o["install_id"] = installID
            o["secret"] = secret.value
            o["engines"] = engines
            o["tabs"] = tabs.map(announceObject)
        case .helloAck(let bundle, let sha):
            o["agent_bundle"] = bundle
            o["agent_bundle_sha"] = sha
        case .call(let id, let method, let params):
            o["id"] = NSNumber(value: id)
            o["method"] = method
            o["params"] = params.foundationValue
        case .result(let id, let result, let error):
            o["id"] = NSNumber(value: id)
            if let result { o["result"] = result.foundationValue }
            if let error { o["error"] = error.foundationValue }
        case .event(let name, let payload):
            o["name"] = name
            o["payload"] = payload.foundationValue
        case .cdpAttach(let target), .cdpDetach(let target), .userInput(let target):
            o["targetId"] = target
        case .cdp(let target, let message):
            o["targetId"] = target
            o["message"] = message
        case .lease(let target, let lease):
            o["targetId"] = target
            o["lease"] = lease.map(leaseObject) ?? NSNull()
        case .tabAccess(let target, let access, let override, let extensions):
            o["targetId"] = target
            o["extension_host_access"] = access
            o["user_override"] = override
            if !extensions.isEmpty { o["extensions"] = extensions }
        case .unknown:
            break
        }
        return o
    }

    /// Decodes one frame body (no length prefix).
    public static func decode(_ body: Data) throws(ProviderCodecError) -> ProviderFrame {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { throw .notJSON }
        let f = Fields(object: object, tag: object["t"] as? String ?? "")
        switch f.tag {
        case "hello":
            let tabs = try (object["tabs"] as? [Any] ?? []).map { item throws(ProviderCodecError) in
                try announce(Fields(object: item as? [String: Any] ?? [:], tag: "TabAnnounce"))
            }
            return .hello(version: UInt32(clamping: try f.uint("version")), providerID: try f.string("provider_id"),
                          installID: try f.string("install_id"), secret: ProviderSecret(try f.string("secret")),
                          engines: try f.strings("engines"), tabs: tabs)
        case "hello.ack":
            return .helloAck(agentBundle: try f.string("agent_bundle"), agentBundleSHA: try f.string("agent_bundle_sha"))
        case "call":
            return .call(id: try f.uint("id"), method: try f.string("method"), params: f.json("params") ?? .null)
        case "result":
            return .result(id: try f.uint("id"), result: f.json("result"), error: f.json("error"))
        case "event":
            return .event(name: try f.string("name"), payload: f.json("payload") ?? .null)
        case "cdp.attach": return .cdpAttach(targetID: try f.string("targetId"))
        case "cdp.detach": return .cdpDetach(targetID: try f.string("targetId"))
        case "cdp": return .cdp(targetID: try f.string("targetId"), message: try f.string("message"))
        case "user.input": return .userInput(targetID: try f.string("targetId"))
        case "lease":
            let lease = try (object["lease"] as? [String: Any]).map { item throws(ProviderCodecError) in
                try leaseValue(Fields(object: item, tag: "Lease"))
            }
            return .lease(targetID: try f.string("targetId"), lease: lease)
        case "tab.access":
            return .tabAccess(targetID: try f.string("targetId"), extensionHostAccess: try f.bool("extension_host_access"),
                              userOverride: (try? f.bool("user_override")) ?? false,
                              extensions: (try? f.strings("extensions")) ?? [])
        case "": throw .missing(field: "t", in: "frame")
        default: return .unknown(tag: f.tag)
        }
    }

    static func announceObject(_ tab: ProviderTabAnnounce) -> [String: Any] {
        ["targetId": tab.targetID, "engine": tab.engine, "workspace": tab.workspace, "profile": tab.profile,
         "url": tab.url, "title": tab.title, "visible": tab.visible]
    }

    static func announce(_ f: Fields) throws(ProviderCodecError) -> ProviderTabAnnounce {
        ProviderTabAnnounce(targetID: try f.string("targetId"), engine: try f.string("engine"),
                            workspace: try f.string("workspace"), profile: try f.string("profile"),
                            url: try f.string("url"), title: (try? f.string("title")) ?? "",
                            visible: (try? f.bool("visible")) ?? false)
    }

    static func leaseObject(_ lease: ProviderLease) -> [String: Any] {
        var o: [String: Any] = ["session": lease.session, "actor": lease.actor, "origin": lease.origin,
                                "label": lease.label, "since_ms": NSNumber(value: lease.sinceMs)]
        if let onBehalfOf = lease.onBehalfOf { o["on_behalf_of"] = onBehalfOf }
        if let state = lease.state { o["state"] = state }
        return o
    }

    static func leaseValue(_ f: Fields) throws(ProviderCodecError) -> ProviderLease {
        ProviderLease(session: try f.string("session"), actor: try f.string("actor"),
                      onBehalfOf: f.object["on_behalf_of"] as? String, origin: try f.string("origin"),
                      label: try f.string("label"), sinceMs: try f.uint("since_ms"),
                      state: f.object["state"] as? String)
    }

    /// Typed field reads with serde's errors (a missing or mistyped field).
    struct Fields {
        let object: [String: Any]
        let tag: String

        func string(_ key: String) throws(ProviderCodecError) -> String {
            guard let value = object[key] as? String else { throw .missing(field: key, in: tag) }
            return value
        }

        func strings(_ key: String) throws(ProviderCodecError) -> [String] {
            guard let value = object[key] as? [String] else { throw .missing(field: key, in: tag) }
            return value
        }

        func bool(_ key: String) throws(ProviderCodecError) -> Bool {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw .missing(field: key, in: tag)
            }
            return number.boolValue
        }

        /// A non-negative integer (u32/u64 on the Rust side).
        func uint(_ key: String) throws(ProviderCodecError) -> UInt64 {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue == number.doubleValue.rounded() else {
                throw .missing(field: key, in: tag)
            }
            return number.uint64Value
        }

        /// A JSON value; absent and `null` are both nil.
        func json(_ key: String) -> DriverJSON? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            return DriverJSON(foundation: value)
        }
    }
}

/// Splits a byte stream into frames (the reader side of the framing).
public nonisolated struct ProviderFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var head = 0
    public let maxFrameBytes: Int

    public init(maxFrameBytes: Int = ProviderCodec.maxFrameBytes) { self.maxFrameBytes = maxFrameBytes }

    public mutating func push(_ bytes: UnsafeRawBufferPointer) { buffer.append(contentsOf: bytes) }
    public mutating func push(_ data: Data) { buffer.append(contentsOf: data) }

    /// The next whole frame, nil while the buffer holds only part of one.
    public mutating func next() throws(ProviderCodecError) -> ProviderFrame? {
        guard buffer.count - head >= 4 else { return nil }
        let length = buffer[head..<head + 4].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maxFrameBytes else { throw .tooLarge(length) }
        guard buffer.count - head - 4 >= length else { return nil }
        let body = Data(buffer[head + 4..<head + 4 + length])
        head += 4 + length
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 1 << 16, head * 2 > buffer.count {
            buffer.removeFirst(head)
            head = 0
        }
        return try ProviderCodec.decode(body)
    }
}
