import AppKit
import Foundation
import Testing
@testable import CmuxNextGallery

/// The gallery's controls and entry rules match the web gallery's: the same vectors
/// (schemas/gallery/env-vectors.json, written by webviews/src/gallery/env.ts) and the same rules.
@MainActor @Suite struct GalleryFormatTests {
    private struct Vectors: Decodable {
        struct Vector: Decodable {
            let query: [String: String]
            let env: Expected
        }
        struct Expected: Decodable {
            let locale: String
            let theme: String
            let colorScheme: String
            let fontFamily: String
            let fontSize: Double
            let density: String
            let scale: Double
            let width: Width
            let height: Double
            let reducedMotion: Bool
            let highContrast: Bool
            let dynamicSize: String
            let windowKey: String
        }
        enum Width: Decodable {
            case named(String), points(Double)
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let points = try? container.decode(Double.self) { self = .points(points) } else {
                    self = .named(try container.decode(String.self))
                }
            }
        }
        let vectors: [Vector]
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func queriesMeanWhatTheyMeanOnTheWeb() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("schemas/gallery/env-vectors.json"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: data).vectors
        #expect(vectors.count > 5)
        for vector in vectors {
            let env = GalleryEnvironment(query: vector.query)
            let expected = vector.env
            #expect(env.locale == expected.locale, "\(vector.query)")
            #expect(env.theme == expected.theme && env.colorScheme.rawValue == expected.colorScheme, "\(vector.query)")
            #expect(env.fontFamily == expected.fontFamily && env.fontSize == expected.fontSize, "\(vector.query)")
            #expect(env.density.rawValue == expected.density && env.scale == expected.scale, "\(vector.query)")
            #expect(env.height == expected.height, "\(vector.query)")
            #expect(env.reducedMotion == expected.reducedMotion && env.highContrast == expected.highContrast)
            #expect(env.dynamicSize.rawValue == expected.dynamicSize && env.windowKey.rawValue == expected.windowKey)
            switch (env.width, expected.width) {
            case (.narrow, .named("narrow")), (.normal, .named("normal")), (.wide, .named("wide")): break
            case let (.points(points), .points(want)): #expect(points == want, "\(vector.query)")
            default: Issue.record("width \(env.width) for \(vector.query)")
            }
        }
    }

    @Test func widthsResolveThroughTheEntrysPresets() {
        var env = GalleryEnvironment(query: ["width": "narrow"])
        #expect(env.widthPoints(presets: GalleryEnvironment.nativeWidths) == 320)
        #expect(env.widthPoints(presets: ["narrow": 280]) == 280)
        env.width = .points(640)
        #expect(env.widthPoints(presets: GalleryEnvironment.nativeWidths) == 640)
    }

    private func entry(_ id: String, variants: [String] = ["default"], covers: [String] = ["swift:NSView"]) -> GalleryEntry {
        GalleryEntry(id: id, title: id, area: "Test", covers: covers, variants: variants.map { GalleryVariant($0) }) { _, _ in
            NSView()
        }
    }

    @Test func theRegistryRefusesWhatTheWebFormatRefuses() {
        let registry = GalleryRegistry()
        registry.register([
            entry("home.list-row", variants: ["default", "unread", "9"]),
            entry("home.list-row"),
            entry("Home.ListRow"),
            entry("home"),
            entry("home.bubble", variants: []),
            entry("home.notice-row", variants: ["Day Separator"]),
            entry("home.pinned-grid", variants: ["1", "1"]),
            entry("home.question-card", covers: []),
        ])
        #expect(registry.entries.map(\.id) == ["home.list-row"])
        #expect(registry.problems.count == 7)
        #expect(registry.entry(id: "home.list-row")?.variant("9") != nil)
    }

    @Test func aBuilderGetsItsVariantAndTheControls() throws {
        let registry = GalleryRegistry()
        registry.register([
            GalleryEntry(id: "test.label", title: "Label", area: "Test", covers: ["swift:NSTextField"],
                         variants: [GalleryVariant("long", note: "A long title")]) { variant, env in
                NSTextField(labelWithString: "\(variant.name) \(env.windowKey.rawValue)")
            },
        ])
        let entry = try #require(registry.entry(id: "test.label"))
        let view = try entry.makeView(try #require(entry.variant("long")), environment: GalleryEnvironment(query: ["windowKey": "inactive"]))
        #expect((view as? NSTextField)?.stringValue == "long inactive")
    }

    @Test func aMissingFixtureThrowsInsteadOfCrashing() {
        let fixture = GalleryFixture("no-such-variant", in: .main, repoPath: "Packages/None/Fixtures/no-such-variant.json")
        #expect(fixture.url == nil)
        #expect(throws: GalleryError.self) { try fixture.data() }
    }
}
