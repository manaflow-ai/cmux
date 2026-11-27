import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator application metadata resolver")
struct SimulatorApplicationMetadataResolverTests {
    @Test("React Native detection accepts exact artifacts and rejects similarly named frameworks")
    func reactNativeArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let frameworks = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = SimulatorApplicationMetadataResolver()
        for falsePositive in ["ReactiveSwift.framework", "ReactiveObjC.framework", "ExpoKit.framework"] {
            let url = frameworks.appendingPathComponent(falsePositive, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        #expect(!resolver.containsReactNative(bundleURL: bundle))

        try FileManager.default.createDirectory(
            at: frameworks.appendingPathComponent("React-Core.framework", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(resolver.containsReactNative(bundleURL: bundle))
    }

    @Test("Bundled JavaScript identifies React Native without dynamic frameworks")
    func bundledJavaScript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!SimulatorApplicationMetadataResolver().containsReactNative(bundleURL: bundle))

        _ = FileManager.default.createFile(
            atPath: bundle.appendingPathComponent("main.jsbundle").path,
            contents: Data()
        )
        #expect(SimulatorApplicationMetadataResolver().containsReactNative(bundleURL: bundle))
    }
}
