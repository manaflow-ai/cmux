import CmuxNextBrowser
import CmuxNextSettings

/// `debug.cef_pages`: every live Chromium page's origin (scheme and host only), whether the content
/// lifecycle hid it, and the renderer client ids that host its frames, so a bench names each
/// renderer process's role (scripts/cmux-next/bench_power.py, scenario `loaded`). Computed only
/// when asked: one shim call per page, no observer and no timer.
@MainActor
func debugCEFPagesReport(_ services: AppServices) -> JSONValue {
    .object(["pages": .array(services.cache.cef.rendererPages.map { page in
        .object(["browser": .number(Double(page.browserID)), "origin": .string(page.origin), "hidden": .bool(page.hidden),
                 "renderer_clients": .array(page.rendererClients.map { .number(Double($0)) })])
    })])
}
