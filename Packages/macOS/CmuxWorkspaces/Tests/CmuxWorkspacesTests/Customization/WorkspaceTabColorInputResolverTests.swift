import Testing
@testable import CmuxWorkspaces

@Suite("Workspace tab color input resolver")
struct WorkspaceTabColorInputResolverTests {
    private let resolver = WorkspaceTabColorInputResolver(namedColors: [
        .init(name: "Purple", hex: "#6A1B9A"),
        .init(name: "Blue", hex: "#1565C0"),
    ])

    @Test("Named colors are case-insensitive and trim whitespace")
    func resolvesNamedColor() {
        #expect(resolver.resolve("  purple\n") == .resolved("#6A1B9A"))
    }

    @Test("Hex colors are normalized to uppercase")
    func resolvesHexColor() {
        #expect(resolver.resolve("#12ab34") == .resolved("#12AB34"))
    }

    @Test("Nil and whitespace-only colors are missing", arguments: [
        nil,
        "",
        " \n\t ",
    ] as [String?])
    func detectsMissingColor(_ input: String?) {
        #expect(resolver.resolve(input) == .missing)
    }

    @Test("Invalid colors report the injected palette in order")
    func reportsNamedColorsForInvalidInput() {
        #expect(
            resolver.resolve("violet") ==
                .invalid(namedColors: ["Purple", "Blue"])
        )
    }
}
