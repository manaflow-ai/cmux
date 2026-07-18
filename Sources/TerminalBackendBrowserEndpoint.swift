import CmuxTerminalBackend
import Foundation

/// Exact identity of one daemon-owned browser runtime.
///
/// `SurfaceID` alone is insufficient because cmuxd restores browser placement,
/// not browser engine state. The daemon authority and daemon-local handle fence
/// a presentation to the runtime that actually emits its frames.
struct TerminalBackendBrowserEndpointIdentity: Equatable, Sendable {
    let authority: BackendAuthority
    let surfaceHandle: UInt64
    let surfaceID: SurfaceID
    let transport: CanonicalBrowserEndpoint.Transport
}

/// A canonical browser endpoint plus non-identity runtime metadata.
struct TerminalBackendBrowserEndpoint: Equatable, Sendable {
    let identity: TerminalBackendBrowserEndpointIdentity
    let source: CanonicalBrowserEndpoint.Source?

    init(authority: BackendAuthority, surface: CanonicalSurface) throws {
        guard surface.kind.lowercased() == "browser" else {
            throw TerminalBackendBrowserEndpointError.notBrowser(
                surfaceID: surface.uuid.rawValue,
                kind: surface.kind
            )
        }
        guard let descriptor = surface.browserEndpoint else {
            throw TerminalBackendBrowserEndpointError.missingDescriptor(
                surfaceID: surface.uuid.rawValue
            )
        }
        identity = TerminalBackendBrowserEndpointIdentity(
            authority: authority,
            surfaceHandle: surface.id,
            surfaceID: surface.uuid,
            transport: descriptor.transport
        )
        source = descriptor.source
    }
}

/// Whether a browser panel is a Swift-owned WKWebView or a projection of one
/// exact daemon browser runtime.
enum BrowserPanelEndpointProvenance: Equatable, Sendable {
    case clientOverlay
    case backend(TerminalBackendBrowserEndpointIdentity)
}

enum TerminalBackendBrowserEndpointError: Error, Equatable, Sendable {
    case notBrowser(surfaceID: UUID, kind: String)
    case missingDescriptor(surfaceID: UUID)
    case clientOverlayCollision(surfaceID: UUID)
    case stalePresentation(
        surfaceID: UUID,
        expected: TerminalBackendBrowserEndpointIdentity,
        actual: TerminalBackendBrowserEndpointIdentity
    )
    case unsupportedContentTransport(TerminalBackendBrowserEndpointIdentity)
    case invalidFactoryResult(surfaceID: UUID)
}

extension TerminalBackendBrowserEndpointError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notBrowser(let surfaceID, let kind):
            "surface \(surfaceID.uuidString) has non-browser kind \(kind)"
        case .missingDescriptor(let surfaceID):
            "canonical browser \(surfaceID.uuidString) has no content endpoint descriptor"
        case .clientOverlayCollision(let surfaceID):
            "client-owned browser \(surfaceID.uuidString) collides with a canonical browser identity"
        case .stalePresentation(let surfaceID, _, _):
            "browser presentation \(surfaceID.uuidString) belongs to a different daemon runtime"
        case .unsupportedContentTransport(let identity):
            "browser content transport \(identity.transport.rawValue) is not implemented for \(identity.surfaceID)"
        case .invalidFactoryResult(let surfaceID):
            "browser endpoint factory returned an unverified presentation for \(surfaceID.uuidString)"
        }
    }
}

/// Factory for a presentation that consumes the exact daemon endpoint.
///
/// Validation runs during topology preflight. Materialization may run only
/// after validation succeeds. Implementations must not return a local WKWebView
/// unless that object actually consumes the endpoint's frame and input streams.
@MainActor
protocol TerminalBackendBrowserEndpointCreating {
    func validate(_ endpoint: TerminalBackendBrowserEndpoint) throws
    func makeBrowserPanel(
        endpoint: TerminalBackendBrowserEndpoint,
        workspaceID: UUID
    ) throws -> BrowserPanel
}

/// Production behavior until cmuxd's PNG/input stream has an AppKit consumer.
@MainActor
struct UnsupportedTerminalBackendBrowserEndpointFactory:
    TerminalBackendBrowserEndpointCreating
{
    func validate(_ endpoint: TerminalBackendBrowserEndpoint) throws {
        throw TerminalBackendBrowserEndpointError.unsupportedContentTransport(
            endpoint.identity
        )
    }

    func makeBrowserPanel(
        endpoint: TerminalBackendBrowserEndpoint,
        workspaceID _: UUID
    ) throws -> BrowserPanel {
        throw TerminalBackendBrowserEndpointError.unsupportedContentTransport(
            endpoint.identity
        )
    }
}

@MainActor
struct TerminalBackendBrowserEndpointResolver {
    let factory: any TerminalBackendBrowserEndpointCreating

    func endpoint(
        authority: BackendAuthority,
        surface: CanonicalSurface
    ) throws -> TerminalBackendBrowserEndpoint {
        try TerminalBackendBrowserEndpoint(authority: authority, surface: surface)
    }

    func validateExisting(
        _ panel: BrowserPanel,
        endpoint: TerminalBackendBrowserEndpoint
    ) throws {
        switch panel.endpointProvenance {
        case .clientOverlay:
            throw TerminalBackendBrowserEndpointError.clientOverlayCollision(
                surfaceID: endpoint.identity.surfaceID.rawValue
            )
        case .backend(let actual):
            guard actual == endpoint.identity else {
                throw TerminalBackendBrowserEndpointError.stalePresentation(
                    surfaceID: endpoint.identity.surfaceID.rawValue,
                    expected: endpoint.identity,
                    actual: actual
                )
            }
        }
    }

    func validateMaterialization(_ endpoint: TerminalBackendBrowserEndpoint) throws {
        try factory.validate(endpoint)
    }

    func materialize(
        _ endpoint: TerminalBackendBrowserEndpoint,
        workspaceID: UUID
    ) throws -> BrowserPanel {
        let panel = try factory.makeBrowserPanel(
            endpoint: endpoint,
            workspaceID: workspaceID
        )
        guard panel.id == endpoint.identity.surfaceID.rawValue,
              panel.workspaceId == workspaceID,
              panel.endpointProvenance == .backend(endpoint.identity) else {
            panel.close()
            throw TerminalBackendBrowserEndpointError.invalidFactoryResult(
                surfaceID: endpoint.identity.surfaceID.rawValue
            )
        }
        return panel
    }
}
