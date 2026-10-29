import CmuxNextCompat
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation
import Testing

/// The Debug tunables a feature `replaces` become that feature's local override once, at
/// launch (`AppServices.launchFeatures`, `FeatureLaunchLocalOverrides`), from Debug Settings' file, so what the app reports (`resolution(of:)`,
/// the Labs card, `features_hash`) is what it does. The Labs page's choice of the same feature goes first.
/// Run: `swift test --filter FeatureTunableLaunchTests`.
@MainActor
struct FeatureTunableLaunchTests {
    private static let work = BackgroundWork(label: "test.feature-tunable-launch")

    private static func tunablesFile(_ values: [String: TunableValue]) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "feature-tunables-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "debug-tunables.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TunableFile.encode(values).blockingWrite(to: file)
        return file
    }

    /// Reads the tunables a feature replaces from `file` on the files lane, as `main` does.
    private static func readOn(_ file: URL) -> LaunchRead<[String: Bool]> {
        let keys = FeatureLaunchLocalOverrides.replacedKeys(of: Feature.registered)
        return LaunchRead(on: work) { TunableFile.boolValues(file, keys: keys) }
    }

    @Test func theFileKeepsOnlyTheBoolsAFeatureReplaces() async throws {
        let file = try Self.tunablesFile([
            "sidebar.slideHoldsContent": .bool(false),
            "agent.chromium": .number(0),
            "motion.renderServer": .bool(true),
        ])
        #expect(await Self.readOn(file).finished() == ["sidebar.slideHoldsContent": false])
        let missing = file.deletingLastPathComponent().appending(path: "none.json")
        #expect(await Self.readOn(missing).finished() == [:])
    }

    @Test func theLaunchResolvesTheTunableOnceWithSourceLocal() async throws {
        var environment = AppEnvironment.current([:])
        let file = try Self.tunablesFile(["sidebar.slideHoldsContent": .bool(false)])
        let tunables = Self.readOn(file)
        _ = await tunables.finished()
        environment.featureTunableOverrides = tunables
        let features = AppServices.launchFeatures(environment)
        try #require(features.channel.allowsLocalOverrides, "tests take the DEV channel")
        #expect(features.resolution(of: .sidebarSlideHoldsContent) == Feature.Resolution(isEnabled: false, source: .local))
        #expect(!WindowRootView.slideHoldsContent(in: features)())
    }

    @Test func aLabsChoiceBeatsTheTunableItReplaced() async throws {
        var environment = AppEnvironment.current([:])
        let file = try Self.tunablesFile(["sidebar.slideHoldsContent": .bool(false)])
        let tunables = Self.readOn(file)
        let labs = LaunchRead(on: Self.work) { FeatureLocalOverrides(values: [Feature.sidebarSlideHoldsContent.name: true]) }
        _ = await tunables.finished()
        _ = await labs.finished()
        environment.featureTunableOverrides = tunables
        environment.featureLocalOverrides = labs
        let features = AppServices.launchFeatures(environment)
        try #require(features.channel.allowsLocalOverrides, "tests take the DEV channel")
        #expect(features.resolution(of: .sidebarSlideHoldsContent) == Feature.Resolution(isEnabled: true, source: .local))
    }
}
