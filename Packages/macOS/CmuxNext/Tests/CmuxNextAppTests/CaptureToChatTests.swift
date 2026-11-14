import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextFocusUI
@testable import CmuxNextSettings
import Foundation
import Testing

/// Capture Screenshot to Chat (`palette.captureScreenshotToChat`) and `chat.capture.toChat`: the
/// catalog offers it as a global key that `app.captureScreenshotGlobalHotKey` gates (off by default),
/// the region argument parses to `screencapture -R`, a taken still goes to the chat route as cmux's,
/// an Esc reaches no chat, and the control method answers `{session, path, bytes}`.
@MainActor @Suite(.serialized) struct CaptureToChatTests {
    static let key = Shortcut("s", modifiers: [.control, .option, .command])

    /// Records registrations instead of calling Carbon.
    final class Recorder: GlobalHotKeyRegistrar {
        var onPress: ((UInt32) -> Void)?
        var registered: [UInt32: CarbonHotKey] = [:]
        func register(_ hotKey: CarbonHotKey, number: UInt32) -> Bool {
            registered[number] = hotKey
            return true
        }
        func unregister(number: UInt32) { registered[number] = nil }
    }

    @MainActor final class Box {
        var attached: [(urls: [URL], source: String?)] = []
        var picks: [ScreenshotToChat.Pick] = []
        var next: ScreenshotToChat.Outcome = .cancelled
    }

    // MARK: The action and its setting

    @Test func theCatalogOffersItInThePaletteAndAsAGlobalKeyOnCtrlOptCmdS() throws {
        let registry = ActionRegistry.standard()
        let descriptor = try #require(registry.descriptor(for: CaptureToChat.action))
        #expect(descriptor.title == "Capture Screenshot to Chat")
        #expect(descriptor.isGlobalHotKey)
        #expect(descriptor.defaultShortcut == Self.key)
        #expect(descriptor.surfaces.contains(.keyboard), "its own row in Settings > Keyboard Shortcuts")
        #expect(descriptor.isPaletteVisible)
        #expect(descriptor.isPersonOnly, "the screen is the person's: the control socket runs chat.capture.toChat instead")
        #expect(registry.shortcutConflicts().isEmpty, "no other default binding takes Ctrl-Opt-Cmd-S")
        #expect(SystemReservedShortcuts.shared.table[Self.key] == nil)
        #expect(GlobalHotKeyService.captureAction == CaptureToChat.action)
    }

    @Test func theSettingIsOffByDefaultAndReadsABool() {
        #expect(CmuxConfigSnapshot.captureScreenshotGlobalHotKeyDefault == false)
        #expect(CmuxConfigSnapshot.captureScreenshotGlobalHotKeyPath == ["app", "captureScreenshotGlobalHotKey"])
        let on = CmuxConfigSnapshot.captureScreenshotGlobalHotKeyDiagnostics(.object(["app": .object(["captureScreenshotGlobalHotKey": .bool(true)])]))
        #expect(on.isEmpty)
        let wrong = CmuxConfigSnapshot.captureScreenshotGlobalHotKeyDiagnostics(.object(["app": .object(["captureScreenshotGlobalHotKey": .string("yes")])]))
        #expect(wrong.map(\.path) == ["app.captureScreenshotGlobalHotKey"])
        #expect(SettingsSchema.agentRefusedKeys["app.captureScreenshotGlobalHotKey"] == .userOnly)
    }

    @Test func theGlobalKeyRegistersOnlyWhileTheSettingIsOnAndAPressTakesAPicture() async throws {
        let registry = ActionRegistry.standard()
        let box = Box()
        CaptureToChat(take: { box.picks.append($0); return .cancelled }, attach: { box.attached.append(($0, $1)) },
                      session: { nil }, source: "com.cmuxterm.app.next").bind(into: registry)
        #expect(registry.globalHotKeys()[CaptureToChat.action] == Self.key, "bound: the catalog offers its key")

        var enabled = false
        let recorder = Recorder()
        let service = GlobalHotKeyService(registry: registry, registrar: recorder, layout: { .ansi },
                                          showHideEnabled: { false }, startAgentEnabled: { false }, captureEnabled: { enabled })
        service.apply()
        let hotKey = try #require(CarbonHotKey(Self.key, layout: .ansi))
        #expect(!recorder.registered.values.contains(hotKey), "off: the key stays other apps'")

        enabled = true
        service.apply()
        let number = try #require(recorder.registered.first(where: { $0.value == hotKey })?.key, "on: Ctrl-Opt-Cmd-S is registered")
        #expect(service.conflicts.isEmpty)
        recorder.onPress?(number)
        try await Self.until { !box.picks.isEmpty }
        #expect(box.picks == [.picker], "a press runs the system's region pick")
        #expect(box.attached.isEmpty, "Esc: nothing goes to a chat")

        enabled = false
        service.apply()
        #expect(!recorder.registered.values.contains(hotKey), "turning it off releases the key")
        service.stop()
    }

    // MARK: The route

    @Test func aTakenStillGoesToTheChatRouteAsCmuxsAndAnEscGoesNowhere() async throws {
        let box = Box()
        let file = URL(fileURLWithPath: "/tmp/Screenshot.png")
        box.next = .taken(file, bytes: 12)
        let capture = CaptureToChat(take: { box.picks.append($0); return box.next }, attach: { box.attached.append(($0, $1)) },
                                    session: { "s-1" }, source: "com.cmuxterm.app.next")
        #expect(await capture.run(.picker) == .taken(file, bytes: 12))
        #expect(box.attached.map(\.urls) == [[file]])
        #expect(box.attached.map(\.source) == ["com.cmuxterm.app.next"])

        box.next = .cancelled
        #expect(await capture.run(.picker) == .cancelled)
        box.next = .failed("no grant")
        #expect(await capture.run(.picker) == .failed("no grant"))
        #expect(box.attached.count == 1, "an Esc or a failure reaches no chat")
    }

    @Test func theAppsSourceIsCmuxsOwnBundle() {
        let route = AgentPaneExternalAttach()
        let capture = CaptureToChat(route: route) { _, _ in }
        #expect(capture.source == Bundle.main.bundleIdentifier, "cmux took it: its chip wears cmux's icon")
        #expect(capture.session() == nil, "no chat took files yet")
    }

    // MARK: The region argument and the answer

    @Test func theRegionParsesToFourWholePointsAndNoneRunsThePick() throws {
        #expect(try ScreenshotToChat.pick(from: [:]) == .picker)
        #expect(try ScreenshotToChat.pick(from: ["region": .null]) == .picker)
        #expect(try ScreenshotToChat.pick(from: ["region": .array([.number(10), .number(20.4), .number(300), .number(199.6)])])
            == .region(x: 10, y: 20, width: 300, height: 200))
        for bad: JSONValue in [.array([.number(1), .number(2), .number(3)]), .string("1,2,3,4"),
                               .array([.number(0), .number(0), .number(0), .number(10)]),
                               .array([.number(0), .number(0), .string("w"), .number(10)])] {
            #expect(throws: ScreenshotToChat.BadRegion.self) { try ScreenshotToChat.pick(from: ["region": bad]) }
        }
    }

    @Test func aRegionRunsScreencaptureWithRAndNoPick() {
        let file = URL(fileURLWithPath: "/tmp/x.png")
        #expect(ScreenshotToChat.arguments(for: .region(x: 1, y: 2, width: 30, height: 40), to: file) == ["-x", "-R1,2,30,40", "-t", "png", "/tmp/x.png"])
        #expect(ScreenshotToChat.arguments(for: .picker, to: file) == ["-i", "-x", "-t", "png", "/tmp/x.png"])
    }

    @Test func theAnswerIsSessionPathAndBytes() {
        let file = URL(fileURLWithPath: "/tmp/Screenshot.png")
        #expect(ScreenshotToChat.answer(session: "s-1", file: file, bytes: 42)
            == .object(["session": .string("s-1"), "path": .string("/tmp/Screenshot.png"), "bytes": .number(42)]))
        #expect(ScreenshotToChat.answer(session: nil, file: file, bytes: 42)["session"] == .null)
    }

    // MARK: Taking the picture (a stub screencapture)

    /// A stub `screencapture` in a fresh folder; it writes its arguments beside itself.
    private static func stub(_ script: String) throws -> (tool: String, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-to-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = root.appendingPathComponent("screencapture-stub.sh")
        let record = root.appendingPathComponent("args").path
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(record)'\nfor last; do :; done\n\(script)\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool.path, root)
    }

    @Test func aTakenRegionIsAPNGKeptUnderChatUploads() async throws {
        let stub = try Self.stub("printf 'PNGDATA' > \"$last\"")
        defer { try? FileManager.default.removeItem(at: stub.root) }
        let folders = ChatUploadFolders(root: stub.root.appendingPathComponent("uploads"))
        let outcome = await ScreenshotToChat(folders: folders, executable: stub.tool).take(.region(x: 5, y: 6, width: 70, height: 80))
        guard case .taken(let file, let bytes) = outcome else { Issue.record("not taken: \(outcome)"); return }
        #expect(bytes == 7)
        #expect(file.path.hasPrefix(folders.root.path), "kept under Chat Uploads, whose expiry covers it")
        #expect(file.lastPathComponent.hasPrefix("Screenshot ") && file.pathExtension == "png")
        let args = try String(contentsOf: stub.root.appendingPathComponent("args"), encoding: .utf8)
        #expect(args.split(separator: "\n").contains("-R5,6,70,80"))
        #expect(!args.split(separator: "\n").contains("-i"), "a region runs no pick")
    }

    @Test func anEscLeavesNoFileAndAFailureSaysWhy() async throws {
        let esc = try Self.stub("exit 1")
        defer { try? FileManager.default.removeItem(at: esc.root) }
        let folders = ChatUploadFolders(root: esc.root.appendingPathComponent("uploads"))
        #expect(await ScreenshotToChat(folders: folders, executable: esc.tool).take(.picker) == .cancelled)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folders.root.path)) ?? []
        #expect(left.isEmpty, "no empty upload folder left behind")

        let failed = try Self.stub("echo 'could not create image from rect' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: failed.root) }
        let outcome = await ScreenshotToChat(folders: folders, executable: failed.tool).take(.region(x: 0, y: 0, width: 1, height: 1))
        guard case .failed(let reason) = outcome else { Issue.record("not failed: \(outcome)"); return }
        #expect(reason.contains("could not create image"))
    }

    private static func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}
