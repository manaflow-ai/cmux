/// One authenticated owner's persisted browser surfaces.
struct BrowserSurfaceArchive: Codable {
    let scope: BrowserPersistenceScope
    let surfaces: [BrowserSurfaceSnapshot]
}
