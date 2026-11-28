import CmuxNextActions
import CmuxNextBrowser
import CmuxNextPalette

/// Lists browser profiles for `browser-profile` arguments (New Tab with
/// Browser Profile…, Move Tab to Browser Profile…): every profile in
/// order, each with its icon or first letter. Other kinds fall through.
final class BrowserProfileTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        guard kind == .browserProfile else { return next.targets(of: kind) }
        return services.browserProfiles.ordered.map { record in
            PaletteTargetOption(id: record.id, title: record.name, subtitle: record.icon, symbol: record.isDefault ? "person.crop.circle" : "person.crop.circle.fill")
        }
    }
}
