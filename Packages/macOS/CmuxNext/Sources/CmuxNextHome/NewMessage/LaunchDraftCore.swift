import CCmuxLaunchDraftFFI
import CmuxHomeCore
import Foundation

/// The rules of a bare launch's held message box, in Rust (cmux-tui/crates/cmux-launch-draft,
/// module `CCmuxLaunchDraftFFI`): what is held, joined or handed over, in what order, each key
/// once; what a cancel gives back; and the text a quit or a release keeps. This is the handle and
/// its JSON, nothing more: ``LaunchChiefHold`` owns the waiters and the deliver loop. Parts cross
/// as `MessagePart`'s own Codable JSON and come back as they went.
final class LaunchDraftCore {
    /// What ``hold(_:key:)`` did with a send.
    enum Outcome: Equatable {
        /// Kept until it is handed to the Chief (after the sends before it).
        case held
        /// The key was already held: the sender waits on that send.
        case joined
        /// The key was already handed to `chief`: the same answer again.
        case alreadyDelivered(chief: String)
        /// The hold was cancelled first.
        case cancelled
        /// Refused by the ABI (parts that would not encode): never expected.
        case invalid
    }

    /// One send under its key.
    struct Send: Decodable {
        let key: String
        let parts: [MessagePart]
    }

    private let handle: OpaquePointer

    init() {
        handle = cmux_launch_draft_new()
    }

    deinit {
        cmux_launch_draft_free(handle)
    }

    /// The real Chief's id, once named.
    var chief: String? { Self.take(cmux_launch_draft_chief(handle)) }

    var isCancelled: Bool { cmux_launch_draft_is_cancelled(handle) }

    /// The sends not handed over yet, in order.
    var held: [Send] { Self.sends(cmux_launch_draft_held(handle)) }

    func hold(_ parts: [MessagePart], key: String) -> Outcome {
        guard let json = Self.json(parts) else { return .invalid }
        var chief: UnsafeMutablePointer<CChar>?
        let code = cmux_launch_draft_hold(handle, key, json, &chief)
        let named = Self.take(chief)
        switch code {
        case CMUX_LAUNCH_DRAFT_HELD: return .held
        case CMUX_LAUNCH_DRAFT_JOINED: return .joined
        case CMUX_LAUNCH_DRAFT_ALREADY_DELIVERED: return named.map { .alreadyDelivered(chief: $0) } ?? .invalid
        case CMUX_LAUNCH_DRAFT_CANCELLED: return .cancelled
        default: return .invalid
        }
    }

    /// Names the Chief; true only for the call that named it.
    func resolve(_ chief: String) -> Bool { cmux_launch_draft_resolve(handle, chief) }

    /// The send to hand over now (the Chief named), the same until ``delivered(_:)``.
    var next: Send? {
        guard let json = Self.take(cmux_launch_draft_next(handle)) else { return nil }
        return try? JSONDecoder().decode(Send.self, from: Data(json.utf8))
    }

    /// The send under `key` was handed over.
    func delivered(_ key: String) { _ = cmux_launch_draft_delivered(handle, key) }

    /// Ends the hold before the Chief was named; the held sends, in order (none after a resolve).
    func cancel() -> [Send] { Self.sends(cmux_launch_draft_cancel(handle)) }

    /// Quit's save: the held sends' text, then `typed`, a line apart. The hold goes on.
    func savedText(typed: String) -> String { Self.decoded(cmux_launch_draft_save_for_quit(handle, typed)) }

    /// A release: cancels the hold (not after a resolve) and returns the held sends' text, then `typed`.
    func parkedText(typed: String) -> String { Self.decoded(cmux_launch_draft_park(handle, typed)) }

    /// The text of `sends`, one send per paragraph.
    static func text(of sends: [[MessagePart]]) -> String {
        guard let json = json(sends) else { return "" }
        return take(cmux_launch_draft_text_of(json)) ?? ""
    }

    /// `typed` after `own` on a line of its own (`typed` alone when `own` is empty); nil when
    /// `typed` is empty.
    static func append(_ typed: String, after own: String) -> String? {
        take(cmux_launch_draft_append(own, typed))
    }

    private static func json(_ value: some Encodable) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func sends(_ text: UnsafeMutablePointer<CChar>?) -> [Send] {
        guard let json = take(text) else { return [] }
        return (try? JSONDecoder().decode([Send].self, from: Data(json.utf8))) ?? []
    }

    /// The draft text of a saved or parked string.
    private static func decoded(_ text: UnsafeMutablePointer<CChar>?) -> String {
        guard let encoded = take(text) else { return "" }
        return take(cmux_launch_draft_decode(encoded)) ?? ""
    }

    /// A returned string, freed.
    private static func take(_ text: UnsafeMutablePointer<CChar>?) -> String? {
        guard let text else { return nil }
        defer { cmux_launch_draft_string_free(text) }
        return String(cString: text)
    }
}
