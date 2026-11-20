// DEBUG and Demo builds only: the link demo is never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import SafariServices
import SwiftUI
import UIKit

/// DEBUG only. Launch with `-CmuxMobileLinkDemo`: the phone types `open URL` in a Mac terminal
/// through the real terminal page, `DaemonTerminalSession` and `DaemonClient`, and a scripted Mac
/// answers as its daemon does (`phone-open-link`, only to a connection that declared
/// `phone-open-link-v1`). The link should open in the Safari view over the terminal.
///
/// The driver's steps (the `debug.link-demo` label, for UI tests): `attached`, `typed`, then
/// `done.safari` (the Safari view is shown) or `done.none.<what the Mac saw>`.
public struct TerminalLinkDemoRoot: View {
    @State private var demo = TerminalLinkDemo()

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileLinkDemo") }

    public var body: some View {
        TerminalTabPage(host: demo.host, insets: EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0), isInteractive: true)
            .overlay(alignment: .topLeading) {
                Text(demo.step)
                    .font(.system(size: 2))
                    .foregroundStyle(.clear)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("debug.link-demo")
            }
            .task { await demo.run() }
    }
}

@MainActor @Observable
final class TerminalLinkDemo {
    nonisolated static let url = "https://example.com/?from=cmux-phone-link-demo"
    let model: TerminalModel
    let host: TerminalTabHost
    private(set) var step = "start"
    @ObservationIgnored private let mac: LinkDemoMac

    init() {
        let mac = LinkDemoMac()
        self.mac = mac
        let session = DaemonTerminalSession(
            surface: 1,
            clientInfo: ["name": "demo iPhone", "kind": "ios", "device_kind": "iphone", "device_name": "demo iPhone"],
            open: { DaemonClient(channel: mac.main) }
        )
        model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "zsh — Mac")
        host = TerminalTabHost(model: model)
    }

    private func mark(_ label: String) {
        step = label
        NSLog("[link-demo] %@", label)
    }

    func run() async {
        let clock = ContinuousClock()
        while !model.connectionState.isAttached { try? await clock.sleep(for: .milliseconds(50)) }
        try? await clock.sleep(for: .seconds(2))
        mark("attached")
        model.composerText = "open \(Self.url)"
        model.send()
        mark("typed")
        let deadline = clock.now + .seconds(20)
        while clock.now < deadline, !Self.safariViewShown() { try? await clock.sleep(for: .milliseconds(100)) }
        try? await clock.sleep(for: .seconds(2))
        mark(Self.safariViewShown() ? "done.safari \(mac.journal)" : "done.none \(mac.journal)")
    }

    static func safariViewShown() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.contains { window in
            var current = window.rootViewController
            while let presented = current?.presentedViewController {
                if presented is SFSafariViewController { return true }
                current = presented
            }
            return false
        }
    }
}

/// The scripted Mac: answers the attach, and once the phone's typed line holds `open URL` and a
/// Return, sends `phone-open-link` to it, but only if its `set-client-info` listed
/// `phone-open-link-v1` (as the daemon's `link_connections` does).
final class LinkDemoMac: @unchecked Sendable {
    let main = FloodChannel(id: 1)
    private let lock = NSLock()
    private var opensLinks = false
    private var typed = Data()
    private var sent = false
    private var log: [String] = []

    var journal: String { lock.withLock { log.joined(separator: ",") } }

    init() {
        main.onSend = { [weak self] line in self?.request(line) }
    }

    private func request(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return }
        lock.withLock { log.append(cmd) }
        let reply = Self.line(["id": id, "ok": true, "data": cmd == "identify"
            ? ["capabilities": ["attach-initial-size"]] as [String: Any] : [String: Any]()])
        switch cmd {
        case "set-client-info":
            let capabilities = object["capabilities"] as? [String] ?? []
            lock.withLock { opensLinks = capabilities.contains("phone-open-link-v1"); log.append("opens-links=\(opensLinks)") }
            main.push([reply])
        case "attach-surface":
            let columns = object["cols"] as? Int ?? 80, rows = object["rows"] as? Int ?? 24
            main.push([Self.line(["event": "vt-state", "surface": 1, "cols": columns, "rows": rows,
                                  "data": Data("\u{1B}[H\u{1B}[2J% ".utf8).base64EncodedString()]), reply])
        case "send":
            let bytes = (object["bytes"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            let fire: Bool = lock.withLock {
                typed.append(bytes)
                let text = String(decoding: typed, as: UTF8.self)
                guard !sent, opensLinks, text.contains("open \(TerminalLinkDemo.url)"), text.contains("\r") else { return false }
                sent = true
                log.append("phone-open-link")
                return true
            }
            main.push([reply])
            if fire {
                main.push([Self.line(["event": "phone-open-link", "terminal_id": "term_0123456789abcdef0123456789abcdef",
                                      "url": TerminalLinkDemo.url])])
            }
        default:
            main.push([reply])
        }
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
#endif
