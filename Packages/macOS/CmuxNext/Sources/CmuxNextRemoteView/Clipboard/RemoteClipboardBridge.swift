public import AppKit
import CmuxNextWakeups

/// The transport's clipboard channel (cap `clipboard.text`): the Rust core behind it decides what
/// goes out and what arrives; this is only the two ends.
public nonisolated protocol RemoteClipboardChannel: AnyObject, Sendable {
    /// The host's clipboard texts, each complete. Finishes with the session.
    func clipboardTexts() -> AsyncStream<String>
    /// The viewer's clipboard now holds `text` (queued for the host, or dropped when it has it).
    func offerClipboard(_ text: String)
}

/// The pasteboard the bridge reads and writes (`NSPasteboard.general`; a fake in tests).
@MainActor
public protocol RemoteClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    func text() -> String?
    /// Replaces the pasteboard's text and returns the change count after the write.
    func setText(_ text: String) -> Int
}

@MainActor
public final class SystemClipboardPasteboard: RemoteClipboardPasteboard {
    public static let shared = SystemClipboardPasteboard()
    private let pasteboard = NSPasteboard.general
    public var changeCount: Int { pasteboard.changeCount }
    public func text() -> String? { pasteboard.string(forType: .string) }
    public func setText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
}

/// Whether a session may sync its clipboard: the `remoteDesktop.clipboard` setting, and for
/// `ownDevicesOnly` only a session to one of the person's own devices.
public nonisolated enum RemoteClipboardPolicy {
    public static func allows(_ setting: RemoteDesktopSettings.Clipboard, ownDevice: Bool) -> Bool {
        switch setting {
        case .always: true
        case .ownDevicesOnly: ownDevice
        case .never: false
        }
    }
}

/// Moves clipboard text between one session and this Mac's pasteboard. The deciding (what is new,
/// what the host already has, paced parts, size bound) is the Rust core's, behind the channel; this
/// only notices a pasteboard change and writes the host's text. The pasteboard is read when the
/// pane becomes key (`checkNow()`, called by the owner) and on a slow timer: a change
/// count read, never a busy poll. Nothing is offered while the session does not hold control.
@MainActor
public final class RemoteClipboardBridge {
    /// How often an active session reads the pasteboard's change count.
    public static let interval: Duration = .milliseconds(750)

    private let channel: any RemoteClipboardChannel
    private let pasteboard: any RemoteClipboardPasteboard
    private let holdsControl: @MainActor () -> Bool
    private let timer = DemandTimer(owner: "RemoteClipboardBridge.check")
    private var seenChangeCount: Int
    private var receiveTask: Task<Void, Never>?
    private var running = false

    /// `holdsControl`: whether the session is in control now (view only sends nothing).
    public init(channel: any RemoteClipboardChannel, pasteboard: any RemoteClipboardPasteboard = SystemClipboardPasteboard.shared,
                holdsControl: @escaping @MainActor () -> Bool) {
        self.channel = channel
        self.pasteboard = pasteboard
        self.holdsControl = holdsControl
        // What is on the pasteboard when the session starts is not a change.
        seenChangeCount = pasteboard.changeCount
    }

    nonisolated deinit {
        timer.cancel()
        receiveTask?.cancel()
    }

    public func start() {
        guard !running else { return }
        running = true
        let texts = channel.clipboardTexts()
        // task-owner: this session's host texts; ends with the session or `stop()`
        receiveTask = Task { [weak self] in
            for await text in texts { self?.apply(hostText: text) }
            // The stream finishes with the session: stop reading the pasteboard.
            if !Task.isCancelled { self?.stop() }
        }
        arm()
    }

    public func stop() {
        running = false
        timer.cancel()
        receiveTask?.cancel()
        receiveTask = nil
    }

    /// Offers the pasteboard's text when it changed since the last look and the session holds control.
    public func checkNow() {
        guard running else { return }
        let count = pasteboard.changeCount
        guard count != seenChangeCount else { return }
        // Seen even while view only: a copy made then is not sent when control comes later.
        seenChangeCount = count
        guard holdsControl(), let text = pasteboard.text(), !text.isEmpty else { return }
        channel.offerClipboard(text)
    }

    private func apply(hostText text: String) {
        // The write is the host's text, not a change to send back.
        seenChangeCount = pasteboard.setText(text)
    }

    private func arm() {
        timer.schedule(after: Self.interval) { @MainActor [weak self] in
            guard let self, running else { return }
            checkNow()
            arm()
        }
    }
}
