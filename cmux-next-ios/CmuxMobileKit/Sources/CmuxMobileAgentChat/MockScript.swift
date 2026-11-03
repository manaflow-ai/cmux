// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxAgentQuestion
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Content for `MockAgentSession`: realistic text, files and diffs.
struct MockScript {
    static let historyAnswer = """
    Every link frame is a fixed 9-byte header followed by the payload:

    ```rust
    pub struct Frame {
        len: u32,       // big endian, payload length
        channel: u32,   // odd = phone, even = Mac
        kind: FrameKind,
        payload: Bytes,
    }
    ```

    | Type | Meaning | Payload |
    | --- | --- | --- |
    | `0` open | open a channel | `{"service", "args"}` |
    | `1` data | raw bytes | bytes |
    | `2` close | close a channel | `{"code", "reason"}` |
    | `3`/`4` | ping / pong | 8-byte nonce |

    The transport underneath never sees channels, so **WebRTC and WireGuard can share it unchanged**.
    """

    static let thinking = """
    The person wants a runtime switch between WebRTC and WireGuard. The frame layer is transport-agnostic, \
    so the change lives in the dialer and settings. Check how `MacLink` is created and where `TransportKind` is referenced first.
    """

    static let readSnippet = """
    pub async fn dial(config: &DialConfig) -> Result<Link> {
        let stream = webrtc::connect(config).await?;
        Ok(Link::new(stream))
    }
    """

    static let searchOutput = """
    cmux-next-ios/PROTOCOL.md:72:  The app exposes Settings → Connection → Transport
    cmux-next-ios/rust/cmux-mobile-link/src/dial.rs:14:  // TODO: TransportKind switch
    cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/Screens.swift:241:  Picker(selection: .constant(0))
    """

    static let planIntro = """
    The frame layer already hides the transport, so the switch only needs to live in the dialer and in Settings. Here's the plan:
    """

    static let plan = [
        ACPPlanEntry(content: "Add `TransportKind` with WebRTC and WireGuard cases", priority: "high"),
        ACPPlanEntry(content: "Route `LinkDialer.dial` through the selected transport", priority: "high"),
        ACPPlanEntry(content: "Run the Swift and Rust link tests", priority: "medium"),
        ACPPlanEntry(content: "Wire the Settings → Connection picker", priority: "medium"),
    ]

    static let kindPath = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTransport/TransportKind.swift"
    static let kindNew = """
    import Foundation

    /// How the phone reaches a Mac. Both produce the same framed `Link`.
    public enum TransportKind: String, CaseIterable, Codable, Sendable {
        /// Data channel `cmux-mobile-link`, TURN when no direct path exists.
        case webrtc
        /// One smoltcp TCP stream to the Mac's overlay address.
        case wireguard

        public var displayName: String {
            switch self {
            case .webrtc: "WebRTC"
            case .wireguard: "WireGuard"
            }
        }
    }
    """

    static let dialerPath = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTransport/LinkDialer.swift"
    static let dialerOld = """
    import Foundation

    /// Opens the framed link to a Mac.
    public struct LinkDialer: Sendable {
        let signaling: SignalingClient
        let iceProvider: ICEProvider

        public init(signaling: SignalingClient, iceProvider: ICEProvider) {
            self.signaling = signaling
            self.iceProvider = iceProvider
        }

        public func dial(_ mac: MacDevice) async throws -> MacLink {
            let servers = try await iceProvider.servers()
            let session = UUID()
            let channel = try await WebRTCDialer(servers: servers)
                .connect(to: mac.id, session: session, signaling: signaling)
            return MacLink(stream: channel)
        }

        public func redial(_ link: MacLink, to mac: MacDevice) async throws -> MacLink {
            await link.close(reason: "redial")
            return try await dial(mac)
        }

        func log(_ message: String) {
            Logger.link.debug("\\(message)")
        }
    }
    """

    static let dialerNew = """
    import Foundation

    /// Opens the framed link to a Mac over the selected transport.
    public struct LinkDialer: Sendable {
        let signaling: SignalingClient
        let iceProvider: ICEProvider
        let transport: @Sendable () -> TransportKind

        public init(signaling: SignalingClient, iceProvider: ICEProvider, transport: @escaping @Sendable () -> TransportKind) {
            self.signaling = signaling
            self.iceProvider = iceProvider
            self.transport = transport
        }

        public func dial(_ mac: MacDevice) async throws -> MacLink {
            let session = UUID()
            switch transport() {
            case .webrtc:
                let servers = try await iceProvider.servers()
                let channel = try await WebRTCDialer(servers: servers)
                    .connect(to: mac.id, session: session, signaling: signaling)
                return MacLink(stream: channel, kind: .webrtc)
            case .wireguard:
                let tunnel = try await WireGuardDialer(signaling: signaling)
                    .connect(to: mac.id, session: session)
                return MacLink(stream: try await tunnel.openStream(port: 7420), kind: .wireguard)
            }
        }

        public func redial(_ link: MacLink, to mac: MacDevice) async throws -> MacLink {
            await link.close(reason: "redial")
            return try await dial(mac)
        }

        func log(_ message: String) {
            Logger.link.debug("\\(message)")
        }
    }
    """

    static let swiftTestOutput = """
    Building for debugging...
    [12/12] Linking CmuxMobileTransportTests
    Test Suite 'LinkDialerTests' started.
    ✔ Test dialsWebRTCByDefault() passed (0.012 seconds)
    ✔ Test dialsWireGuardWhenSelected() passed (0.019 seconds)
    ✔ Test redialClosesTheOldLink() passed (0.004 seconds)
    ✔ Test run with 3 tests passed after 0.041 seconds.
    """

    static let cargoOutput = """
       Compiling cmux-mobile-link v0.1.0 (cmux-next-ios/rust/cmux-mobile-link)
        Finished `test` profile [unoptimized + debuginfo] target(s) in 6.82s
         Running unittests src/lib.rs
    running 9 tests
    test frame::tests::round_trips_every_kind ... ok
    test frame::tests::rejects_oversized_payload ... ok
    test mux::tests::odd_channels_belong_to_the_phone ... ok
    test dial::tests::wireguard_falls_back_to_relay ... ok
    test result: ok. 9 passed; 0 failed; 0 ignored
    """

    static let beforeQuestion = "Both test suites pass. Two product decisions before I wire Settings:"
    static let beforeQuestionDenied = "Swift tests pass; I skipped the Rust tests as you asked. Two product decisions before I wire Settings:"

    /// The waiting turn's copy uses its own id, so a driver that answers it never
    /// collides with the next turn's `q-transport`.
    static func question(session: String, id: String = "q-transport") -> AgentQuestion {
        AgentQuestion(
            id: id,
            source: AgentQuestion.Source(harness: .claude, session: session, permission: "perm-question", agentName: "Claude"),
            items: [
                AgentQuestion.Item(
                    id: "default", header: "Cellular", prompt: "Which transport should be the default on cellular?",
                    options: [
                        AgentQuestion.Option(id: "webrtc", label: "WebRTC", detail: "Fastest to connect; uses TURN when there's no direct path."),
                        AgentQuestion.Option(id: "wireguard", label: "WireGuard", detail: "One tunnel for every service; falls back to the relay."),
                    ]
                ),
                AgentQuestion.Item(
                    id: "surfaces", header: "Settings", prompt: "Where should the switch appear?",
                    options: [
                        AgentQuestion.Option(id: "connection", label: "Settings → Connection"),
                        AgentQuestion.Option(id: "per-mac", label: "Per Mac", detail: "Long-press a Mac in the sidebar."),
                        AgentQuestion.Option(id: "debug", label: "Debug menu only"),
                    ],
                    multiSelect: true
                ),
            ]
        )
    }

    static let settingsPath = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/ConnectionSettings.swift"
    static let settingsOld = """
    import SwiftUI

    struct ConnectionSettings: View {
        var body: some View {
            Section("Connection") {
                Picker(selection: .constant(0)) {
                    Text("WebRTC").tag(0)
                    Text("WireGuard").tag(1)
                } label: {
                    Label("Transport", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
    }
    """

    static func settingsNew(cellular: String) -> String {
        """
        import SwiftUI

        struct ConnectionSettings: View {
            @AppStorage("transport") private var transport: TransportKind = .\(cellular)

            var body: some View {
                Section("Connection") {
                    Picker(selection: $transport) {
                        ForEach(TransportKind.allCases, id: \\.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    } label: {
                        Label("Transport", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
            }
        }
        """
    }

    static func finalAnswer(cellular: String) -> String {
        let name = cellular == "wireguard" ? "WireGuard" : "WebRTC"
        return """
        ## Done: the transport is switchable

        `LinkDialer` now asks a `TransportKind` provider on every dial, so switching in Settings tears the link down and redials. **\(name)** is the default on cellular.

        | Transport | Connect time | Survives network change | Relay |
        | --- | --- | --- | --- |
        | WebRTC | ~350 ms | ICE restart | TURN |
        | WireGuard | ~120 ms | Roams natively | TeamHub DO |

        The redial cost is dominated by the handshake. With loss rate $p$ and round trip $r$, the expected connect time is roughly

        $$
        T \\approx \\frac{k \\cdot r}{1 - p} + t_{\\text{ice}}
        $$

        where $k = 2$ for WireGuard and $k = 4$ for WebRTC.

        To try it from the simulator:

        ```bash
        nx-remote -- swift test --package-path cmux-next-ios/CmuxMobileKit --filter LinkDialerTests
        ```

        Next steps:

        1. Persist the choice per Mac once the registry stores device prefs.
        2. Show the active transport in the connection banner.
        - [x] Swift tests pass
        - [x] Rust tests pass
        - [ ] Dogfood on cellular
        """
    }

    static func shortAnswer(for prompt: String) -> String {
        """
        Sure. I looked at the README and the current branch. Short answer to *\(prompt.prefix(60))*:

        - The change is isolated to the dialer.
        - Nothing else needs to move.

        Want me to open a PR?
        """
    }

    static let subagentAnswer = """
    The transport switch holds up. Three subagents checked it in parallel:

    | Area | Result |
    | --- | --- |
    | WebRTC dialer | First LAN attempt can time out once (8 s ICE), retry succeeds |
    | WireGuard | Handshake retries bounded; relay after 3 s without UDP |
    | Tests | 14 dialer tests, 31 link tests pass |

    The full write-up is in [the report](cmux-next-ios/verify/transport-report.html) with a [PDF copy](cmux-next-ios/verify/transport-report.pdf), the screenshot is `cmux-next-ios/verify/screenshots/terminal.png` and the recording `cmux-next-ios/verify/recordings/demo.mp4`. Relay timings are in `cmux-next-ios/verify/relay-rtt.csv`. Background: [WireGuard whitepaper](https://www.wireguard.com/papers/wireguard.pdf) and [RFC 8445 (ICE)](https://www.rfc-editor.org/rfc/rfc8445).

    The device build runs in [the xcodebuild tab](cmux://tab/tab_00000000000000000000000000000030).
    """

    /// A small generated image for the history turn's attachment.
    static var attachmentPNG: Data? {
        #if canImport(UIKit)
        let size = CGSize(width: 240, height: 160)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.9).setFill()
            for row in 0..<3 {
                UIBezierPath(roundedRect: CGRect(x: 16, y: 24 + CGFloat(row) * 40, width: 208, height: 28), cornerRadius: 8).fill()
            }
        }
        return image.pngData()
        #else
        return nil
        #endif
    }
}
#endif
