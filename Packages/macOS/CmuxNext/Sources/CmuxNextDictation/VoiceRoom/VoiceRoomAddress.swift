public import Foundation

/// The room server's address, from `labs.voiceRoomURL`.
public struct VoiceRoomAddress: Equatable, Sendable {
    /// The local room server (`bun experiments/voice-room/src/server.ts`).
    public static let local = VoiceRoomAddress(base: URL(string: "http://127.0.0.1:4788/") ?? URL(fileURLWithPath: "/"))

    /// The room page; the API paths hang off it.
    public let base: URL

    /// The address in a setting: empty is ``local``; anything that is not an http(s) URL is nil.
    ///
    /// - Parameter setting: The `labs.voiceRoomURL` value.
    public init?(setting: String) {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .local
            return
        }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), components.host?.isEmpty == false
        else { return nil }
        if !components.path.hasSuffix("/") { components.path += "/" }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        self.init(base: url)
    }

    private init(base: URL) {
        self.base = base
    }

    /// Where lines go (`POST`).
    public var transcript: URL { base.appending(path: "api/transcript") }

    /// The room's event socket, joined as an observer (not a person in the room).
    public var events: URL {
        var components = URLComponents(url: base.appending(path: "ws"), resolvingAgainstBaseURL: false)
        components?.scheme = base.scheme == "https" ? "wss" : "ws"
        components?.queryItems = [URLQueryItem(name: "observer", value: "1")]
        return components?.url ?? base
    }
}
