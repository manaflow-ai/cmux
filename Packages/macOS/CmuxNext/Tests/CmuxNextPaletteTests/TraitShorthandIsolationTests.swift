import Testing

struct TraitShorthandIsolationTests {
    @Test func paletteRankerCanBeReadFromNonisolatedCode() {
        #expect(makePaletteRanker().isRecursive)
    }
}

private nonisolated func makePaletteRanker() -> PaletteRankerRequired {
    .paletteRanker
}
