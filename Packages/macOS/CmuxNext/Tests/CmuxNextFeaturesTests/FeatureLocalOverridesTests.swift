import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation
import Testing

/// The Labs page's local feature choices (resolution step 3): read at launch,
/// applied by DEV and NIGHTLY only, written for the next launch (about:flags,
/// components/flags_ui/pref_service_flags_storage.cc).
/// Run: `swift test --filter FeatureLocalOverridesTests`.
struct FeatureLocalOverridesTests {
    private static let perfThing = feature(0, "perfThing")
    private static let labsThing = feature(1, "labsThing")
    private static let registry = FeatureRegistry([perfThing, labsThing])
    private static let work = BackgroundWork(label: "test.feature-local-overrides")

    private static func feature(_ index: Int, _ name: String) -> Feature {
        Feature(index: index, name: name, owner: "PL-test", description: "A test feature.", kind: .labs, process: .app,
                chromiumFeature: nil, defaults: FeatureDefaults(all: false), expires: nil, params: [], stories: [],
                sticky: false, runtimeMutable: false)
    }

    /// Reads `file` on the files lane, as the App's launch read does.
    private static func read(_ file: URL) async throws -> (FeatureLocalOverrides, [FeatureLocalOverrides.FileError]) {
        try await work.run(.userVisible, mayBlock: .files) {
            var failures: [FeatureLocalOverrides.FileError] = []
            let read = FeatureLocalOverrides.read(file) { failures.append($0) }
            return (read, failures)
        }
    }

    private static func file() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "feature-local-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: FeatureLocalOverrides.fileName)
    }

    @Test func noFileIsNoChoice() async throws {
        let (read, failures) = try await Self.read(Self.file())
        #expect(read == FeatureLocalOverrides())
        #expect(failures.isEmpty)
    }

    @Test func aFileThatIsNotAnObjectOfBooleansAppliesNothingAndIsReported() async throws {
        let file = Self.file()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"labsThing": "yes"}"#.utf8).blockingWrite(to: file)
        let (read, failures) = try await Self.read(file)
        #expect(read == FeatureLocalOverrides())
        #expect(failures.count == 1)
    }

    @Test func choicesApplyOnDevAndNightlyOnly() {
        let local = FeatureLocalOverrides(values: ["labsThing": true, "noSuchThing": true])
        for channel in [Feature.Channel.dev, .nightly] {
            let list = FeatureList(registry: Self.registry, channel: channel, local: local)
            #expect(list.resolution(of: Self.labsThing) == Feature.Resolution(isEnabled: true, source: .local))
            #expect(list.resolution(of: Self.perfThing) == Feature.Resolution(isEnabled: false, source: .channelDefault))
        }
        let release = FeatureList(registry: Self.registry, channel: .release, local: local)
        #expect(release.resolution(of: Self.labsThing) == Feature.Resolution(isEnabled: false, source: .channelDefault))
    }

    /// A choice shows at once as the next launch's, leaves this launch's as it was, and is written for the next read.
    @MainActor @Test func aChoiceIsWrittenForTheNextLaunch() async throws {
        let file = Self.file()
        let launch = FeatureLocalOverrides(values: ["labsThing": true])
        let store = FeatureLocalOverrideStore(registry: Self.registry, channel: .nightly, launch: launch, file: file, work: Self.work)
        try? store.set("perfThing", false)
        try? store.set("labsThing", nil)
        #expect(store.launch == launch)
        #expect(store.next == FeatureLocalOverrides(values: ["perfThing": false]))
        await store.written()
        let (written, failures) = try await Self.read(file)
        #expect(written == FeatureLocalOverrides(values: ["perfThing": false]))
        #expect(failures.isEmpty)
        let next = FeatureList(registry: Self.registry, channel: .nightly, local: written)
        #expect(next.resolution(of: Self.perfThing) == Feature.Resolution(isEnabled: false, source: .local))
        #expect(next.resolution(of: Self.labsThing).source == .channelDefault)
    }

    @MainActor @Test func releaseAndUnknownNamesAreRefused() async {
        let file = Self.file()
        let release = FeatureLocalOverrideStore(registry: Self.registry, channel: .release, launch: FeatureLocalOverrides(),
                                                file: file, work: Self.work)
        #expect(throws: FeatureLocalOverrideStore.Refusal.channelTakesNoLocalChoices(.release)) {
            try release.set("labsThing", true)
        }
        let dev = FeatureLocalOverrideStore(registry: Self.registry, channel: .dev, launch: FeatureLocalOverrides(),
                                            file: file, work: Self.work)
        #expect(throws: FeatureLocalOverrideStore.Refusal.unknownFeature("noSuchThing")) {
            try dev.set("noSuchThing", true)
        }
        await dev.written()
        #expect(release.next == FeatureLocalOverrides())
        #expect(dev.next == FeatureLocalOverrides())
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }
}
