// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import CmuxRemoteComputerUse
import CmuxRemoteWire
import Foundation
import Testing

/// The worker contract's control lines and the engine callbacks' JSON, as the worker reads them.
@Suite struct WorkerWireTests {
    private let secret = String(repeating: "ab", count: 32)

    @Test func configureCarriesThePolicyAsIsAndRefusesAnUnsafeLine() throws {
        let line: [String: Any] = ["type": "configure", "config": ["mode": "lookOnly", "deniedApps": ["com.apple.Terminal"]],
                                   "socket": "/tmp/l/w-cu.sock", "secret": secret, "state_dir": "/tmp/s/computer-use",
                                   "machine": "Studio", "motion": ["enabled": false, "speed": 2]]
        guard case .configure(let configuration) = try #require(WorkerControl(line: line)) else {
            Issue.record("not a configure line")
            return
        }
        #expect(PolicyFlags(configuration.policy).mode == "lookOnly")
        let policy = try #require(try JSONSerialization.jsonObject(with: configuration.policy) as? [String: Any])
        #expect(policy["deniedApps"] as? [String] == ["com.apple.Terminal"])
        #expect(configuration.machine == "Studio")
        #expect(configuration.motion == CursorMotionSettings(enabled: false, speed: 2))
        // Round trip.
        let again = try #require(RemoteWire.object(configuration.line.dropLast()))
        #expect(WorkerControl(line: again) == .configure(configuration))

        // A relative socket, a short secret or a relative state directory is refused.
        for (key, value) in [("socket", "w-cu.sock"), ("secret", "abcd"), ("state_dir", "state")] {
            var bad = line
            bad[key] = value
            #expect(WorkerControl(line: bad) == nil, "\(key)")
        }
    }

    @Test func configAndApprovalsLines() throws {
        let config = try #require(WorkerControl(line: ["type": "config", "config": ["mode": "off", "showCursor": false]]))
        guard case .config(let policy, let motion) = config else {
            Issue.record("not a config line")
            return
        }
        #expect(PolicyFlags(policy).isOff)
        #expect(!PolicyFlags(policy).showCursor)
        #expect(motion == nil)
        #expect(WorkerControl(line: ["type": "config", "config": "fullAccess"]) == nil)

        #expect(WorkerControl(line: ["type": "approvals", "id": 3, "action": "forget", "app_id": "com.apple.Notes"])
            == .approvals(id: 3, action: .forget("com.apple.Notes")))
        #expect(WorkerControl(line: ["type": "approvals", "action": "revoke_sessions"]) == .approvals(id: nil, action: .revokeSessions))
        // An app action with no app is not an edit.
        #expect(WorkerControl(line: ["type": "approvals", "id": 4, "action": "always"]) == .unknown(id: 4, type: "approvals"))
        #expect(ApprovalEdit.revokeSessions.engineArguments?.action == "revoke_sessions")
        #expect(ApprovalEdit.list.engineArguments == nil)
        #expect(WorkerControl(line: ["type": "nope", "id": 9]) == .unknown(id: 9, type: "nope"))
    }

    @Test func thePolicyFlagsDefaultToTheContractDefaults() {
        let flags = PolicyFlags(Data("{}".utf8))
        #expect(flags.mode == "fullAccess")
        #expect(flags.showCursor && flags.pauseOnTakeover && !flags.isOff)
    }

    @Test func cursorMotionFollowsTheAppAndReduceMotion() throws {
        #expect(CursorMotionSettings().animates(reduceMotion: false))
        #expect(!CursorMotionSettings().animates(reduceMotion: true))
        #expect(!CursorMotionSettings(enabled: false).animates(reduceMotion: false))
        // A speed out of range is clamped; a bad one is 1.
        #expect(try #require(CursorMotionSettings(["speed": 100])).speed == 4)
        #expect(try #require(CursorMotionSettings(["speed": -1])).speed == 1)
        #expect(CursorMotionSettings("fast") == nil)
    }

    @Test func permissionRequestsUseCmuxRemotesNames() throws {
        let line = try #require(WorkerReport.requestPermission("screen_capture"))
        #expect(RemoteWire.object(line.dropLast())?["permission"] as? String == "screen-recording")
        #expect(RemoteWire.object(try #require(WorkerReport.requestPermission("accessibility")).dropLast())?["permission"] as? String
            == "accessibility")
        #expect(WorkerReport.requestPermission("camera") == nil)
        #expect(RemoteWire.object(WorkerReport.ready(pid: 12, socket: "/s").dropLast())?["type"] as? String == "ready")
    }

    @Test func approvalQuestionsAndTheirChoices() throws {
        let json = Data(#"{"session":"s1","agent":"Claude","app":{"id":"com.apple.Notes","name":"Notes"},"remember":true,"from_machine":"Studio"}"#.utf8)
        let question = try #require(ApprovalQuestion(json: json))
        #expect(question == ApprovalQuestion(session: "s1", agent: "Claude", appID: "com.apple.Notes", appName: "Notes",
                                             remember: true, fromMachine: "Studio"))
        #expect(question.choices == [.never, .deny, .always, .allowSession, .allowOnce])
        var once = question
        once.remember = false
        #expect(once.choices == [.deny, .allowSession, .allowOnce])
        // No name: the id stands in; neither: not a question.
        let bare = try #require(ApprovalQuestion(json: Data(#"{"app":{"id":"com.x.y"}}"#.utf8)))
        #expect(bare.appName == "com.x.y")
        #expect(ApprovalQuestion(json: Data(#"{"app":{}}"#.utf8)) == nil)
        // The C ABI's answer numbers.
        #expect(ApprovalAnswer.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5])
    }

    @Test func approvalTextNamesTheAgentTheAppAndTheMachine() {
        let local = ApprovalQuestion(session: "s", agent: "Codex", appID: "a", appName: "Safari", remember: true)
        #expect(ComputerUseText.approvalTitle(local) == "Codex wants to use Safari")
        var remote = local
        remote.fromMachine = "Studio"
        #expect(ComputerUseText.approvalTitle(remote) == "Codex on Studio wants to use Safari")
        var nobody = local
        nobody.agent = ""
        #expect(ComputerUseText.approvalTitle(nobody) == "An agent wants to use Safari")
        #expect(ComputerUseText.choice(.always, app: "Safari") == "Always Allow Safari")
    }

    @Test func captureTargets() {
        #expect(CaptureTarget(json: Data(#"{"window":"4242"}"#.utf8)) == .window(4242))
        #expect(CaptureTarget(json: Data(#"{"window":17}"#.utf8)) == .window(17))
        #expect(CaptureTarget(json: Data(#"{"display":null}"#.utf8)) == .display(nil))
        #expect(CaptureTarget(json: Data(#"{"display":"1"}"#.utf8)) == .display(1))
        #expect(CaptureTarget(json: Data(#"{"window":"x"}"#.utf8)) == nil)
        #expect(CaptureTarget(json: Data(#"{}"#.utf8)) == nil)
    }

    @Test func rgbaIsTightlyPacked() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let image = try #require(context.makeImage())
        let rgba = try #require(ScreenCapture.rgba(image))
        #expect(rgba.count == 3 * 2 * 4)
        #expect(Array(rgba.prefix(4)) == [255, 0, 0, 255])
    }
}

/// The agent cursor's events and geometry.
@Suite struct AgentCursorEventTests {
    @Test func eventsDecodeFromTheEnginesJSON() throws {
        let move = try #require(AgentCursorEvent(json: Data(#"{"kind":"move","session":"s","label":"Claude","at":{"x":10.5,"y":20}}"#.utf8)))
        #expect(move == AgentCursorEvent(kind: .move, session: "s", label: "Claude", at: CGPoint(x: 10.5, y: 20)))
        let typing = try #require(AgentCursorEvent(json: Data(#"{"kind":"typing","session":"s","label":"C","at":null,"text":"hi"}"#.utf8)))
        #expect(typing.at == nil && typing.text == "hi")
        #expect(try #require(AgentCursorEvent(json: Data(#"{"kind":"hide","session":"s"}"#.utf8))).kind == .hide)
        #expect(AgentCursorEvent(json: Data(#"{"kind":"warp","session":"s"}"#.utf8)) == nil)
        #expect(AgentCursorEvent(json: Data(#"{"kind":"move"}"#.utf8)) == nil)
    }

    @Test func theCaptionIsOneShortLine() {
        #expect(AgentCursorEvent.caption("hello") == "hello")
        #expect(AgentCursorEvent.caption("a\nb\tc") == "a b c")
        let long = AgentCursorEvent.caption(String(repeating: "x", count: 40))
        #expect(long.count == 24 && long.hasSuffix("\u{2026}"))
    }

    @Test func desktopPointsFlipToAppKit() {
        let geometry = AgentCursorGeometry(primaryHeight: 1000)
        #expect(geometry.appKit(CGPoint(x: 5, y: 100)) == CGPoint(x: 5, y: 900))
        let screens = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)]
        #expect(AgentCursorGeometry.screen(containing: CGPoint(x: 150, y: 50), in: screens) == screens[1])
        // Off every screen: the nearest one.
        #expect(AgentCursorGeometry.screen(containing: CGPoint(x: 260, y: 50), in: screens) == screens[1])
        #expect(AgentCursorGeometry.screen(containing: .zero, in: []) == nil)
    }

    @MainActor @Test func theOverlayFollowsShowCursorAndHide() {
        let overlay = AgentCursorOverlay(reduceMotion: { true })
        overlay.show(AgentCursorEvent(kind: .look, session: "a", label: "Claude"))
        #expect(overlay.sessionCount == 1)
        overlay.show(AgentCursorEvent(kind: .hide, session: "a"))
        #expect(overlay.sessionCount == 0)
        overlay.enabled = false
        overlay.show(AgentCursorEvent(kind: .look, session: "b", label: "Codex"))
        #expect(overlay.sessionCount == 0)
    }

    @MainActor @Test func approvalQuestionsQueueAndEndUnavailableOnStop() {
        let panel = ApprovalPanel()
        let answers = Answers()
        let question = ApprovalQuestion(session: "s", agent: "Claude", appID: "a", appName: "Notes", remember: false)
        panel.ask(question) { answers.add($0) }
        panel.ask(question) { answers.add($0) }
        #expect(panel.openCount == 2)
        panel.cancelAll()
        #expect(panel.openCount == 0)
        #expect(answers.all == [.unavailable, .unavailable])
    }
}

private final class Answers: @unchecked Sendable { // crash-allow: a test recorder written on the main actor only
    private(set) var all: [ApprovalAnswer] = []
    func add(_ answer: ApprovalAnswer) { all.append(answer) }
}
