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

    /// Registers `GET /v1/surfaces/{id}/screen` (Task 1.14).
    ///
    /// Parses `format`, `region`, `wrap`, `trim` query parameters,
    /// rejects `format=raw` upfront with 400 + the streaming-only
    /// message per D29, and delegates to
    /// ``CmuxTerminalAccess/TerminalAccessService/readScreen(_:)``.
    /// The text branch emits a plain-text envelope; the cells branch
    /// delegates to ``CellGridJSON`` for the wire shape.
    static func registerScreenRead(
        into table: inout RouteTable,
        service: any TerminalAccessService
    ) {
        table.register(method: "GET", pattern: "/v1/surfaces/*/screen") { req in
            let segs = req.path.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard segs.count == 4,
                  segs[0] == "v1",
                  segs[1] == "surfaces",
                  segs[3] == "screen"
            else {
                return JSONResponses.error(.badRequest(reason: "bad path"))
            }
            guard let handle = SurfaceHandle.parse(segs[2]) else {
                return JSONResponses.error(.unknownSurface)
            }
            // D29 — format=raw on /screen is streaming-only.
            let formatRaw = (req.query["format"] ?? "text").lowercased()
            if formatRaw == "raw" {
                return JSONResponses.error(
                    .badRequest(
                        reason: "format=raw is streaming-only; use /stream?mode=raw"
                    )
                )
            }
            guard let format = ScreenFormat(rawValue: formatRaw) else {
                return JSONResponses.error(
                    .badRequest(reason: "format must be text|cells")
                )
            }
            let regionRaw = (req.query["region"] ?? "viewport").lowercased()
            guard let region = ScreenRegion(rawValue: regionRaw) else {
                return JSONResponses.error(
                    .badRequest(reason: "region must be viewport|screen|scrollback")
                )
            }
            let wrapRaw = (req.query["wrap"] ?? "preserve").lowercased()
            guard let wrap = WrapPolicy(rawValue: wrapRaw) else {
                return JSONResponses.error(
                    .badRequest(reason: "wrap must be preserve|join")
                )
            }
            let trim = (req.query["trim"] ?? "true").lowercased() != "false"
            do {
                let result = try await service.readScreen(
                    ScreenReadRequest(
                        handle: handle,
                        format: format,
                        region: region,
                        wrap: wrap,
                        trim: trim
                    )
                )
                switch result {
                case .text(let t):
                    return JSONResponses.json(200, [
                        "format": "text",
                        "region": regionRaw,
                        "cols": t.cols,
                        "rows": t.rows,
                        "alt_screen": t.altScreen,
                        "title": t.title as Any,
                        "text": t.text,
                    ])
                case .cells(let g):
                    return JSONResponses.json(
                        200,
                        CellGridJSON.encode(g, region: regionRaw)
                    )
                }
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
