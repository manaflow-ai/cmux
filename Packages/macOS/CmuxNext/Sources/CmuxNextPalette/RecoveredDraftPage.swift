public import CmuxNextDesign
import Foundation

/// Open Recovered Draft… (`file.openRecoveredDraft`, R96): a palette page of the recovery drafts
/// on disk, newest first, read when the page opens. Return runs the store's `restoreHandler`, the
/// same path as the launch notice's Open, so a draft whose one launch toast has gone is still
/// reachable. Opening a draft never removes it; a save or Don't Save does.
@MainActor
public struct RecoveredDraftPage {
    public static let id = "file.openRecoveredDraft"
    private let store: RecoveryDraftStore

    public init(store: RecoveryDraftStore) {
        self.store = store
    }

    public var spec: PalettePageSpec {
        let provider = AsyncPaletteProvider(id: Self.id) { [weak store] in
            guard let store else { return [] }
            return await store.drafts().reversed().map { Self.item(for: $0, store: store) }
        }
        return PalettePageSpec(id: Self.id, title: PaletteStrings.recoveredDraftsTitle,
                               placeholder: PaletteStrings.recoveredDraftsPlaceholder, symbol: "doc.badge.clock",
                               providers: [provider])
    }

    static func item(for draft: RecoveryDraft, store: RecoveryDraftStore) -> PaletteItem {
        PaletteItem(
            id: draft.id, title: draft.title, subtitle: draft.filePath,
            accessory: RelativeDateTimeFormatter().localizedString(for: draft.savedAt, relativeTo: Date()),
            symbol: "doc.badge.clock", keywords: [draft.filePath ?? ""], isEnabled: store.restoreHandler != nil,
            primary: PaletteCommand(id: "open", title: PaletteStrings.open, symbol: "return",
                                    effect: .perform { [weak store] in store?.restoreHandler?(draft) }))
    }
}
