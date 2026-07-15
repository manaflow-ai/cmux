/// One authenticated owner's persisted browser surfaces.
struct BrowserSurfaceArchive: Codable {
    let scope: BrowserPersistenceScope
    let surfaces: [BrowserSurfaceSnapshot]
    let generation: String?

    init(
        scope: BrowserPersistenceScope,
        surfaces: [BrowserSurfaceSnapshot],
        generation: String? = nil
    ) {
        self.scope = scope
        self.surfaces = surfaces
        self.generation = generation
    }
}
