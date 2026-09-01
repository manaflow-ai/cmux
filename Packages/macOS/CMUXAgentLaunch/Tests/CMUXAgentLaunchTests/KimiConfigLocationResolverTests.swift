import CMUXAgentLaunch
import Foundation
import Testing

@Suite("KimiConfigLocationResolver")
struct KimiConfigLocationResolverTests {
    private struct Home {
        let root: URL

        func directory(_ name: String) -> URL {
            root.appendingPathComponent(name, isDirectory: true)
        }

        func config(_ name: String) -> URL {
            directory(name).appendingPathComponent("config.toml", isDirectory: false)
        }
    }

    private func makeHome() throws -> Home {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kimi-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Home(root: root)
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeConfig(_ url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try "default_model = \"user-model\"\n".write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("Candidate directories put Kimi Code first and honor overrides")
    func candidateDirectoriesHonorOverrides() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let plain = KimiConfigLocationResolver(environment: ["HOME": home.root.path])
        #expect(plain.candidateDirectories().map(\.path) == [
            home.directory(".kimi-code").path,
            home.directory(".kimi").path,
        ])

        let overridden = KimiConfigLocationResolver(environment: [
            "HOME": home.root.path,
            "KIMI_CODE_HOME": "/opt/kimi-code",
            "KIMI_SHARE_DIR": "  ",
        ])
        #expect(overridden.candidateDirectories().map(\.path) == [
            "/opt/kimi-code",
            home.directory(".kimi").path,
        ])

        let tilde = KimiConfigLocationResolver(environment: [
            "HOME": home.root.path,
            "KIMI_SHARE_DIR": "~/relocated-kimi",
        ])
        // Tilde overrides expand against the process HOME, not the injected one.
        #expect(
            tilde.candidateDirectories().last?.path
                == NSHomeDirectory() + "/relocated-kimi"
        )
        #expect(tilde.candidateDirectories().last?.path != home.directory("relocated-kimi").path)
    }

    @Test("Fallback prefers an existing config, then an existing directory, then Kimi Code")
    func fallbackFollowsExistenceOrder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let environment = ["HOME": home.root.path]

        #expect(
            KimiConfigLocationResolver(environment: environment).fallbackConfigDirectory().path
                == home.directory(".kimi-code").path
        )

        try makeDirectory(home.directory(".kimi"))
        #expect(
            KimiConfigLocationResolver(environment: environment).fallbackConfigDirectory().path
                == home.directory(".kimi").path
        )

        try makeDirectory(home.directory(".kimi-code"))
        #expect(
            KimiConfigLocationResolver(environment: environment).fallbackConfigDirectory().path
                == home.directory(".kimi-code").path
        )

        try writeConfig(home.config(".kimi"))
        try FileManager.default.createDirectory(
            at: home.config(".kimi-code"),
            withIntermediateDirectories: true
        )
        #expect(
            KimiConfigLocationResolver(environment: environment).fallbackConfigDirectory().path
                == home.directory(".kimi").path
        )
    }

    @Test("A doctor report is trusted only when it names a config in an existing directory")
    func doctorReportIsTrustedOnlyWhenUsable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let resolver = KimiConfigLocationResolver(environment: ["HOME": home.root.path])
        let reported = home.config("probed")
        try makeDirectory(reported.deletingLastPathComponent())

        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "config.toml: \(reported.path) ok\ntui.toml: skipped\n"
            ) == reported
        )
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "checking \"\(reported.path)\", ok\n"
            ) == reported
        )
        #expect(resolver.reportedConfigURL(inDoctorOutput: "") == nil)
        #expect(resolver.reportedConfigURL(inDoctorOutput: "config.toml: skipped\n") == nil)
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "error: unknown command \"doctor\"\n"
            ) == nil
        )
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "config.toml: \(home.config("never-created").path)\n"
            ) == nil
        )
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "tui.toml: \(home.directory("probed").path)/tui.toml\n"
            ) == nil
        )
    }

    @Test("A reported path keeps spaces and survives a labelled line")
    func doctorReportKeepsPathsWithSpaces() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let resolver = KimiConfigLocationResolver(environment: ["HOME": home.root.path])
        let spaced = home.config("Kimi Code")
        try makeDirectory(spaced.deletingLastPathComponent())

        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "config.toml: \(spaced.path) ok\n"
            ) == spaced
        )
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "checked \"\(spaced.path)\"\n"
            ) == spaced
        )
        #expect(
            resolver.reportedConfigURL(inDoctorOutput: "\(spaced.path)\n") == spaced
        )
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "ran /usr/bin/env kimi, read \(spaced.path)\n"
            ) == spaced
        )
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "config.toml: \(home.directory("Kimi Code").path)/xconfig.toml\n"
            ) == nil
        )
    }

    @Test("A doctor report respects its parsing bounds")
    func doctorReportRespectsParsingBounds() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let resolver = KimiConfigLocationResolver(environment: ["HOME": home.root.path])
        let reported = home.config("bounded")
        try makeDirectory(reported.deletingLastPathComponent())

        // A usable path past the 8 KB report bound is never reached.
        let padding = String(repeating: "x", count: 8_200)
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "\(padding)\nconfig.toml: \(reported.path) ok\n"
            ) == nil
        )

        // A usable path on a line over the 1 KB line bound is skipped.
        let longLinePrefix = String(repeating: "y", count: 1_100)
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "\(longLinePrefix) config.toml: \(reported.path) ok\n"
            ) == nil
        )

        // A usable path preceded by more than 32 candidate path starts on the
        // same line falls outside the capped scan and is not found.
        let decoys = (0..<32).map { "/decoy\($0)" }.joined(separator: " ")
        #expect(
            resolver.reportedConfigURL(
                inDoctorOutput: "\(decoys) \(reported.path) ok\n"
            ) == nil
        )

        // The same path, reported alone, is found — confirming the bound,
        // not the fixture, is what rejects it above.
        #expect(
            resolver.reportedConfigURL(inDoctorOutput: "\(reported.path)\n") == reported
        )
    }

    @Test("Locations keep the reported config active and list the rest once")
    func locationsDedupeAgainstTheActiveConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let resolver = KimiConfigLocationResolver(environment: ["HOME": home.root.path])

        let reported = home.config("probed")
        let probed = resolver.locations(reportedConfigURL: reported)
        #expect(probed.active == reported)
        #expect(probed.secondary.map(\.path) == [
            home.config(".kimi-code").path,
            home.config(".kimi").path,
        ])
        #expect(probed.all.count == 3)

        try makeDirectory(home.directory(".kimi"))
        let fallback = KimiConfigLocationResolver(environment: ["HOME": home.root.path])
            .locations(reportedConfigURL: nil)
        #expect(fallback.active.path == home.config(".kimi").path)
        #expect(fallback.secondary.map(\.path) == [home.config(".kimi-code").path])
    }

    @Test("Locations collapse config paths that resolve to the same file")
    func locationsCollapseSymlinkedDirectories() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let real = home.directory("kimi-code-home")
        let link = home.directory("kimi-share-link")
        try makeDirectory(real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let locations = KimiConfigLocationResolver(environment: [
            "HOME": home.root.path,
            "KIMI_CODE_HOME": real.path,
            "KIMI_SHARE_DIR": link.path,
        ]).locations(reportedConfigURL: nil)

        #expect(locations.active.path == real.appendingPathComponent("config.toml").path)
        #expect(locations.secondary.isEmpty)
    }
}
