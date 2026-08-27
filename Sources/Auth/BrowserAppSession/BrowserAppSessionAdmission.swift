struct BrowserAppSessionAdmission {
    private(set) var owner: BrowserAppSessionAuthOwner?
    private(set) var acceptsHandoffs = false

    @discardableResult
    mutating func beginTransition() -> Bool {
        let changed = acceptsHandoffs || owner != nil
        owner = nil
        acceptsHandoffs = false
        return changed
    }

    mutating func resume(for owner: BrowserAppSessionAuthOwner) {
        self.owner = owner
        acceptsHandoffs = true
    }

    func allows(_ owner: BrowserAppSessionAuthOwner) -> Bool {
        acceptsHandoffs && self.owner == owner
    }
}
