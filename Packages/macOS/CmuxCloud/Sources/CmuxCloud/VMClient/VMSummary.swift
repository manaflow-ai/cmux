import CMUXDebugLog
import CmuxAuthRuntime
import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation

/// A Cloud machine from an authenticated control-plane response.
public struct VMSummary: Sendable {
    public init(
        id: String,
        provider: String,
        status: String,
        image: String,
        createdAt: Int64,
        base: VMBaseSummary? = nil,
        kind: VMMachineKind? = nil,
        capabilities: VMCapabilities = .all,
        displayName: String? = nil,
        slug: String? = nil,
        freeAccessExpiresAt: Int64? = nil,
        addressIPv4: String? = nil,
        addressIPv6: String? = nil,
        cmuxTuiContract: String? = nil,
        cloudWelcomeEligible: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.status = status
        self.image = image
        self.createdAt = createdAt
        self.base = base
        self.kind = kind
        self.capabilities = capabilities
        self.displayName = displayName
        self.slug = slug
        self.freeAccessExpiresAt = freeAccessExpiresAt
        self.addressIPv4 = addressIPv4
        self.addressIPv6 = addressIPv6
        self.cmuxTuiContract = cmuxTuiContract
        self.cloudWelcomeEligible = cloudWelcomeEligible
    }

    public let id: String
    public let provider: String
    public let status: String
    public let image: String
    public let createdAt: Int64
    public let base: VMBaseSummary?
    /// The backend's `kind` (desktop/base); when omitted, ``resolvedKind`` infers it from the image id.
    public var kind: VMMachineKind? = nil
    /// Verbs the provider can honor (`GET /api/vm` → `capabilities`); none sent means everything.
    public var capabilities: VMCapabilities = .all
    /// User-chosen label; the id stays the machine's address.
    public var displayName: String?
    /// Server-generated three-word name (`sleepy-teal-otter`), fixed for the
    /// machine's life and unique among the owner's live machines. Nil on
    /// machines created before the backend assigned names.
    public var slug: String?
    /// When the free plan's access window closes for this machine (epoch ms);
    /// nil on paid plans or when the window is disabled server-side.
    public var freeAccessExpiresAt: Int64?
    /// The machine's address on its owner's private network (reachable over
    /// the WireGuard tunnel); nil for machines created before private networking.
    public var addressIPv4: String?
    public var addressIPv6: String?
    /// The image's cmux-tui attach contract from the create receipt
    /// (`"snapshot-v2"`: baked daemon, trusted private-network listener).
    /// Only the create response carries it; list reads leave it nil.
    public var cmuxTuiContract: String?

    /// Whether the backend granted this machine its creator's first-use welcome.
    public var cloudWelcomeEligible: Bool

    /// The name to show people: the label when set, else the generated slug,
    /// else the machine id.
    public var preferredName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let slug, !slug.isEmpty { return slug }
        return id
    }

    /// The address to hand a person who asked for "the IP": v4 when the network
    /// allocated one (shorter, pasteable anywhere), else v6.
    public var preferredPrivateAddress: String? { addressIPv4 ?? addressIPv6 }

    /// Whether the machine has a screen: the server's word first, image name second.
    public var resolvedKind: VMMachineKind { kind ?? VMMachineKind.inferred(fromImage: image) }
}
