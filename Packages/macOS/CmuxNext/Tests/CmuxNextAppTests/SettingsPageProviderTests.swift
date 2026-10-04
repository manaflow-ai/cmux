import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing

/// R82: the React Settings page is the only Settings UI, and `SettingsPageProvider` serves its
/// `cmux.settings/1` ops (webviews/src/pages/settings/ops.ts) from the app's settings owner with
/// the daemon's shapes and codes: rows, snapshot, validated writes with the v2 mutation result,
/// managed and invalid refusals, idempotent replays, and one changed event per load.
@MainActor @Suite(.serialized) struct SettingsPageProviderTests {
    private let context = PageCallContext(page: "cmux.settings")

    private func make(managed: ManagedPreferences = ManagedPreferences()) async throws -> (SettingsPageProvider, SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "settings-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        await settings.reload()
        let provider = SettingsPageProvider(settings: settings, domains: { ["sounds": ["Glass"]] })
        return (provider, settings, directory)
    }

    @Test func listAnswersOneRowPerSchemaSettingOfTheSection() async throws {
        let (provider, _, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let all = try await provider.call("cmux.settings.list", params: [:], context: context)
        #expect(all.arrayValue?.count == SettingsSchema.all.count)
        let appearance = try await provider.call("cmux.settings.list", params: ["section": "appearance"], context: context)
        let rows = try #require(appearance.arrayValue)
        #expect(rows.count == SettingsSchema.all.filter { $0.section == .appearance }.count)
        let row = try #require(rows.first)
        #expect(row["key"]?.stringValue != nil)
        #expect(row["customized"] == .bool(false))
        #expect(row["managed"] == .null)
    }

    @Test func setWritesThroughTheOwnerAndAnswersTheMutationResult() async throws {
        let (provider, settings, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try #require(SettingsSchema.all.first { $0.id == "appearance.density" })
        let result = try await provider.call("cmux.settings.set", params: ["key": "appearance.density", "value": "compact",
                                                                           "idempotency_key": "k1"], context: context)
        #expect(result["value"]?["keys"] == ["appearance.density"])
        #expect(result["revision"]?.stringValue == String(settings.loadCount), "the v2 revision is a decimal string")
        #expect(result["replayed"] == .bool(false))
        #expect(settings.validatedWrites["appearance.density"] == 1, "the write went through the validated writer")
        #expect(try await settings.file.value(at: descriptor.path) == "compact")

        let replay = try await provider.call("cmux.settings.set", params: ["key": "appearance.density", "value": "compact",
                                                                           "idempotency_key": "k1"], context: context)
        #expect(replay["replayed"] == .bool(true))
        #expect(settings.validatedWrites["appearance.density"] == 1, "a retried key does not write again")

        _ = try await provider.call("cmux.settings.reset", params: ["key": "appearance.density", "idempotency_key": "k2"], context: context)
        #expect(try await settings.file.value(at: descriptor.path) == nil)
    }

    @Test func refusalsUseThePageCodes() async throws {
        let (provider, settings, directory) = try await make(managed: ManagedPreferences(forced: ["appearance.density": "compact"]))
        defer { try? FileManager.default.removeItem(at: directory) }
        await settings.reload()
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.set", params: ["key": "nope.nothing", "value": true], context: context)
        }
        do {
            _ = try await provider.call("cmux.settings.set", params: ["key": "appearance.density", "value": "comfortable"], context: context)
            Issue.record("a managed key was written")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.managed")
            #expect(error.details?["source"] == "device")
        }
        do {
            _ = try await provider.call("cmux.settings.set", params: ["key": "nope.nothing", "value": true], context: context)
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.invalid")
        }
        let wrongType = try #require(SettingsSchema.all.first {
            $0.id != "appearance.density" && SettingsSchema.agentSettableKeys.contains($0.id) && !$0.accepts(.object(["x": 1]))
        })
        do {
            _ = try await provider.call("cmux.settings.set", params: ["key": .string(wrongType.id), "value": .object(["x": 1])], context: context)
            Issue.record("a value the schema refuses was written")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.invalid")
        }
        let snapshot = try await provider.call("cmux.settings.snapshot", params: [:], context: context)
        #expect(snapshot["managed"]?["appearance.density"]?["source"] == "device")
        #expect(snapshot["domains"]?["sounds"] == ["Glass"])
    }

    @Test func aWriteFromAnyWriterSendsOneChangedEvent() async throws {
        let (provider, settings, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var events: [JSONValue] = []
        let subscription = try await provider.subscribe("cmux.settings.changed", filter: [:], context: context) { events.append($0) }
        defer { subscription.cancel() }
        await Task.yield()
        let descriptor = try #require(SettingsSchema.all.first { $0.id == "appearance.density" })
        try await settings.setSetting(descriptor, to: "compact", by: .user)
        await settings.reload()
        for _ in 0..<200 where events.isEmpty { await Task.yield() }
        #expect(events.first?["keys"] == ["appearance.density"])
    }

    /// R82 commit 2: the host lists op answers the app's lists, and without a host it is
    /// unavailable (the page then shows no lists, never an error banner).
    @Test func hostListsComeFromTheHost() async throws {
        let (_, settings, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = SettingsPageProvider(settings: settings, hostLists: { ["machines": [["id": "m1"]]] })
        let lists = try await provider.call("cmux.settings.host.lists", params: [:], context: context)
        #expect(lists["machines"]?.arrayValue?.count == 1)
        let bare = SettingsPageProvider(settings: settings)
        do {
            _ = try await bare.call("cmux.settings.host.lists", params: [:], context: context)
            Issue.record("a provider without a host answered lists")
        } catch let error as PageError {
            #expect(error.code == "cmux.page.unavailable")
        }
    }

    /// R82 commit 4: the theme picker's write goes to the host closure; an unknown level is
    /// invalid params; wallpaper thumbnails answer only catalog ids.
    @Test func themeWritesAndThumbnailsAreBounded() async throws {
        let (provider, _, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var writes: [String] = []
        provider.setTheme = { level, spec in
            guard level == "terminal" else { throw CocoaError(.featureUnsupported) }
            writes.append("\(level)=\(spec ?? "config")")
        }
        provider.acceptsTheme = { $0.contains(":") }
        _ = try await provider.call("cmux.settings.theme.set", params: ["level": "terminal", "spec": "Dracula"], context: context)
        _ = try await provider.call("cmux.settings.theme.set", params: ["level": "terminal"], context: context)
        #expect(writes == ["terminal=Dracula", "terminal=config"])
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.theme.set", params: ["level": "nope", "spec": "x"], context: context)
        }
        let accepts = try await provider.call("cmux.settings.theme.accepts", params: ["text": "light:A,dark:B"], context: context)
        #expect(accepts["accepts"] == .bool(true))

        let thumbnails = SettingsBackdropThumbnails(choices: [])
        let url = try #require(URL(string: "cmux-page://cmux.settings/backdrop/system%3A%2Fetc%2Fhosts"))
        let refused = await thumbnails.resource(for: PageResourceRequest(prefix: "backdrop", path: ["system:/etc/hosts"], url: url))
        #expect(refused == nil, "only catalog ids are served")
    }

    /// R82 commit 5: a live preview applies without writing the file; preview.end restores; a
    /// managed key or a refused value is not previewed.
    @Test func livePreviewAppliesWithoutAWriteAndEnds() async throws {
        let (provider, settings, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try #require(SettingsSchema.all.first { $0.id == "appearance.density" })
        let answer = try await provider.call("cmux.settings.preview", params: ["key": "appearance.density", "value": "compact"], context: context)
        #expect(answer["previewing"] == "appearance.density")
        #expect(settings.previewingKey == "appearance.density")
        #expect(try await settings.file.value(at: descriptor.path) == nil, "a preview never writes")
        _ = try await provider.call("cmux.settings.preview.end", params: ["key": "appearance.density"], context: context)
        #expect(settings.previewingKey == nil)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.preview", params: ["key": "appearance.density", "value": .object(["x": 1])],
                                        context: context)
        }
        let (managedProvider, managedSettings, managedDirectory) = try await make(managed: ManagedPreferences(forced: ["appearance.density": "compact"]))
        defer { try? FileManager.default.removeItem(at: managedDirectory) }
        await managedSettings.reload()
        do {
            _ = try await managedProvider.call("cmux.settings.preview", params: ["key": "appearance.density", "value": "comfortable"], context: context)
            Issue.record("a managed key was previewed")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.managed")
        }
    }

    /// SECURITY (agent_settable): the Settings page writes a user-only key only for a call backed
    /// by a real gesture in its view; a script call with no gesture is a page write and is refused.
    @Test func userOnlyKeysNeedAGestureFromTheSettingsPage() async throws {
        let (provider, settings, directory) = try await make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let params: JSONValue = ["key": "history.terminalCommands", "value": false, "idempotency_key": "g1"]
        do {
            _ = try await provider.call("cmux.settings.set", params: params, context: context)
            Issue.record("a page write with no gesture changed a user-only key")
        } catch let error as PageError {
            #expect(error.code == "cmux.settings.user_only")
        }
        #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == nil)
        let gesture = PageCallContext(page: "cmux.settings", userGesture: true)
        _ = try await provider.call("cmux.settings.set", params: ["key": "history.terminalCommands", "value": false, "idempotency_key": "g2"],
                                    context: gesture)
        #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == .bool(false))
        let otherPage = PageCallContext(page: "cmux.cloud", userGesture: true)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.set", params: ["key": "history.terminalCommands", "value": true, "idempotency_key": "g3"],
                                        context: otherPage)
        }
    }
}
