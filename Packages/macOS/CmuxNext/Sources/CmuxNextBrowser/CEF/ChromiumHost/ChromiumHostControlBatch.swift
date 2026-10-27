#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// One drain of a ``ChromiumHostControlChannel``: everything the reader took
/// since the last drain, handed to `onMessages` in one call (one main-thread
/// task per drain, so at most one per frame).
///
/// Iterating it yields every message but the MIRROR and ACK frames, and
/// applies those frames to the channel's ``ChromiumHostMirror`` just before
/// the message after them (task 016b): a handler reads the values the host
/// pushed before its message (the host pushes them first) and none pushed
/// after, as Chrome's UI thread runs each IPC message in arrival order
/// (`ipc/ipc_channel_proxy.cc`, `Context::OnDispatchMessage`). A frame
/// applies once, however often the batch is iterated; frames after the last
/// message apply when `onMessages` returns. Iteration stops at a malformed
/// frame, and the channel then ends the connection.
struct ChromiumHostControlBatch: Sequence {
    private let cursor: Cursor

    init(_ messages: [ChromiumHostControlMessage], mirror: ChromiumHostMirror) {
        cursor = Cursor(messages: messages, mirror: mirror)
    }

    func makeIterator() -> Iterator {
        Iterator(cursor: cursor)
    }

    /// Whether the drain holds a message besides MIRROR and ACK frames.
    var hasMessages: Bool {
        cursor.messages.contains { !ChromiumHostMirror.takes($0) }
    }

    /// Applies the frames iteration has not; the index of a malformed one
    /// (no message from it on was yielded), or nil.
    func finish() -> Int? {
        cursor.apply(upTo: cursor.messages.count) ? nil : cursor.refused
    }

    struct Iterator: IteratorProtocol {
        fileprivate let cursor: Cursor
        private var position = 0

        fileprivate init(cursor: Cursor) {
            self.cursor = cursor
        }

        mutating func next() -> ChromiumHostControlMessage? {
            while position < cursor.messages.count {
                let index = position
                position += 1
                let message = cursor.messages[index]
                if ChromiumHostMirror.takes(message) { continue }
                guard cursor.apply(upTo: index) else { return nil }
                return message
            }
            return nil
        }
    }

    /// How far the drain's frames have applied to the mirror.
    fileprivate final class Cursor {
        let messages: [ChromiumHostControlMessage]
        let mirror: ChromiumHostMirror
        private var applied = 0
        /// The index of the malformed frame, once one is found.
        private(set) var refused: Int?

        init(messages: [ChromiumHostControlMessage], mirror: ChromiumHostMirror) {
            self.messages = messages
            self.mirror = mirror
        }

        /// Applies the MIRROR and ACK frames before `end` not applied yet.
        /// False once a malformed one is found.
        func apply(upTo end: Int) -> Bool {
            guard refused == nil else { return false }
            while applied < end {
                let message = messages[applied]
                if ChromiumHostMirror.takes(message), !mirror.apply(message) {
                    refused = applied
                    return false
                }
                applied += 1
            }
            return true
        }
    }
}
#endif
