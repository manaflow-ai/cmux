public import Foundation
public import Observation

/// What the current document did with permissions, recorded by the engine:
/// Page Info also lists permissions a page requested, used, or had
/// blocked during this page load, not only ones the user changed. Reset on
/// every cross-document commit.
@Observable
public final class PageInfoActivity {
    /// Origin of the committed document.
    public private(set) var origin: String?
    /// Requested this page load (asked, auto-allowed, or auto-blocked).
    public private(set) var requested: Set<SitePermissionKind> = []
    /// Capturing now (camera, microphone).
    public private(set) var inUse: Set<SitePermissionKind> = []
    /// Changed in Page Info or Site settings since the page loaded; stays
    /// listed even when set back to the default, and needs a reload to apply
    /// ("Reload this page to apply your updated settings").
    public private(set) var changedSinceLoad: Set<SitePermissionKind> = []
    /// DER certificates the engine saw for the main frame's server, leaf
    /// first. Set for loads that failed verification, where the page has no
    /// committed certificate to ask for.
    public private(set) var failedCertificateChain: [Data] = []
    public private(set) var failedCertificateReason: String?

    public init() {}

    public func documentCommitted(origin: String?) {
        guard origin != self.origin || !requested.isEmpty || !changedSinceLoad.isEmpty else { return }
        self.origin = origin
        requested = []
        inUse = []
        changedSinceLoad = []
    }

    public func recordRequest(_ kinds: Set<SitePermissionKind>) {
        requested.formUnion(kinds)
    }

    public func setInUse(_ kinds: Set<SitePermissionKind>) {
        if inUse != kinds { inUse = kinds }
    }

    public func recordChange(_ kind: SitePermissionKind) {
        changedSinceLoad.insert(kind)
    }

    public func recordChanges(_ kinds: Set<SitePermissionKind>) {
        changedSinceLoad.formUnion(kinds)
    }

    public func recordCertificateFailure(chain: [Data], reason: String?) {
        failedCertificateChain = chain
        failedCertificateReason = reason
    }

    public func clearCertificateFailure() {
        guard !failedCertificateChain.isEmpty || failedCertificateReason != nil else { return }
        failedCertificateChain = []
        failedCertificateReason = nil
    }
}
