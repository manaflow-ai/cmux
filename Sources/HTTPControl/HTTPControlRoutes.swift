import CmuxTerminalAccess
import Foundation

/// Top-level registration helper that wires
/// ``CmuxTerminalAccess/TerminalAccessService`` methods into a
/// ``RouteTable`` for ``HTTPControlServer``.
///
/// Each registrar maps one route (or a small family of routes) to its
/// service call, JSON wire shape, and error mapping. Splitting per
/// route keeps the test seams narrow and lets later phases register
/// only what they need (e.g. tests can omit `/input` to verify
/// read-only servers).
enum HTTPControlRoutes {
    /// Registers `GET /v1/surfaces` (Task 1.12).
    ///
    /// Per Errata E17 the underlying ``TerminalAccessService``
    /// signature is `async throws`, so the handler must `try await`
    /// and map ``TerminalAccessError`` onto its HTTP envelope.
    static func registerSurfaceList(
        into table: inout RouteTable,
        service: any TerminalAccessService
    ) {
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            do {
                let surfaces = try await service.listSurfaces()
                return JSONResponses.json(200, SurfaceListJSON.encode(surfaces))
            } catch let e as TerminalAccessError {
                return JSONResponses.error(e)
            } catch {
                return JSONResponses.error(
                    .ghosttyError(String(describing: error))
                )
            }
        }
    }
}
