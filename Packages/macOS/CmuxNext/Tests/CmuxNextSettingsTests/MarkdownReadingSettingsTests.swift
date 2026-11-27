import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The markdown viewer's reading rows (Settings > Appearance > Markdown Viewer; the viewer's
/// Reading Settings popover writes the same keys): each has the page's default and range, refuses
/// values outside it, and an agent may set it (looks only).
struct MarkdownReadingSettingsTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let key: String
        let fallback: JSONValue
        let accepted: [JSONValue]
        let refused: [JSONValue]
        var testDescription: String { key }
    }

    static let rows: [Row] = [
        // Wide enough for an ultrawide monitor (user 2026-10-19); full width stays its own key.
        Row(key: "markdown.layout.width", fallback: .number(72),
            accepted: [.number(30), .number(100), .number(160), .number(500), .number(1000)],
            refused: [.number(10), .number(1001), .number(4000), .string("72ch")]),
        Row(key: "markdown.layout.fullWidth", fallback: .bool(false), accepted: [.bool(true)], refused: [.string("yes")]),
        Row(key: "markdown.font.preset", fallback: .string("system"), accepted: [.string("serif"), .string("mono")],
            refused: [.string("comic")]),
        Row(key: "markdown.font.lineHeight", fallback: .number(1.6), accepted: [.number(1), .number(2.4)],
            refused: [.number(0.5), .number(4)]),
        Row(key: "markdown.spacing.paragraph", fallback: .number(1), accepted: [.number(0), .number(3)],
            refused: [.number(-1), .number(5)]),
        // Code is a share of the body size (user 2026-10-19: "code blocks' font size looks too big").
        Row(key: "markdown.code.scale", fallback: .number(0.875), accepted: [.number(0.6), .number(0.85), .number(1.25)],
            refused: [.number(0.5), .number(2), .string("85%")]),
        Row(key: "markdown.tables", fallback: .string("scroll"), accepted: [.string("wrap")], refused: [.string("hide")]),
        Row(key: "markdown.theme", fallback: .string("app"), accepted: [.string("light"), .string("dark")],
            refused: [.string("sepia")]),
    ]

    @Test(arguments: rows)
    func eachRowHasThePageDefaultAndRange(_ row: Row) throws {
        let path = row.key.split(separator: ".").map(String.init)
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        #expect(descriptor.defaultValue == row.fallback)
        #expect(descriptor.effectiveValue(in: .object([:])) == row.fallback)
        for value in row.accepted { #expect(descriptor.accepts(value), "\(row.key) accepts \(value)") }
        for value in row.refused { #expect(!descriptor.accepts(value), "\(row.key) refuses \(value)") }
        #expect(SettingsSchema.agentSettableKeys.contains(row.key))
    }

    @Test func theDefaultCodeSizeIsALittleSmallerThanTheText() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["markdown", "code", "scale"]))
        guard case .number(let scale)? = descriptor.defaultValue else {
            Issue.record("markdown.code.scale has no number default")
            return
        }
        #expect(scale >= 0.85 && scale <= 0.9)
    }

    @Test func theFixedCodeBlockSizeStaysValidButOffTheSettingsPage() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["markdown", "code", "blockSize"]))
        #expect(descriptor.defaultValue == nil)
        #expect(descriptor.accepts(.number(13)))
        #expect(!descriptor.isShownOnSettingsPage)
    }

    @Test func anUltrawideStoredWidthIsTheEffectiveValue() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["markdown", "layout", "width"]))
        let root: JSONValue = .object(["markdown": .object(["layout": .object(["width": .number(640)])])])
        #expect(descriptor.effectiveValue(in: root) == .number(640))
    }

    @Test func aStoredWidthIsTheEffectiveValue() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["markdown", "layout", "width"]))
        let root: JSONValue = .object(["markdown": .object(["layout": .object(["width": .number(96)])])])
        #expect(descriptor.effectiveValue(in: root) == .number(96))
        #expect(descriptor.isCustomized(in: root))
    }
}
