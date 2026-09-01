import Testing

@Suite("Right-sidebar mode catalog")
struct RightSidebarModeCatalogTests {
    @Test("CLI aliases resolve to canonical modes")
    func aliasesResolve() {
        let catalog = RightSidebarModeCatalog()

        #expect(catalog.entry(forCLIArgument: "vault")?.id == "sessions")
        #expect(catalog.entry(forCLIArgument: "sourceControl")?.id == "sourceControl")
        #expect(catalog.entry(forCLIArgument: "CLOUD")?.id == "machines")
        #expect(catalog.canonicalCLIArgument("vms") == "machines")
    }

    @Test("Help vocabulary preserves catalog order")
    func helpVocabularyIsStable() {
        #expect(
            RightSidebarModeCatalog().cliArgumentsDescription
                == "files|find|vault|sessions|feed|dock|machines|cloud|vms|source-control|sourcecontrol|custom|custom-sidebar"
        )
    }
}
