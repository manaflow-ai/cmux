/// The Import screen's variants, in gallery order (the first is the default).
/// Add a variant: one file with one `OnboardingScreenVariant` type, then
/// list it here.
@MainActor
enum ImportVariants {
    static let all: [any OnboardingScreenVariant.Type] = [
        StandardImport.self,
        ImportTableRows.self,
        ImportEverything.self,
        ImportGrouped.self,
        ImportSplit.self,
        ImportNarrow.self,
        ImportGlassCard.self,
        ImportKindToggles.self,
        ImportSummaryLine.self,
        ImportBottomAnchored.self,
        ImportSingleMenu.self,
        ImportEditorial.self,
    ]
}
