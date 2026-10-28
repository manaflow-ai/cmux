import struct CmuxSafeConcurrency.OwnerReference
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextPalette

/// Lists browser profiles for `browser-profile` arguments (New Tab with
/// Browser Profile…, Move Tab to Browser Profile…): every profile in
/// order, each with its icon or first letter. Other kinds fall through.
final class BrowserProfileTargetSource: PaletteTargetSource {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        servicesReference = OwnerReference(services: services)
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        guard kind == .browserProfile else { return next.targets(of: kind) }
        guard let services else { return [] }
        return services.browserProfiles.ordered.map { record in
            PaletteTargetOption(id: record.id, title: record.name, subtitle: record.icon, symbol: record.isDefault ? "person.crop.circle" : "person.crop.circle.fill")
        }
    }

    /// Descriptions belong to kinds `next` lists.
    func currentDescription(of target: ActionTargetRef) -> String? {
        next.currentDescription(of: target)
    }
}
