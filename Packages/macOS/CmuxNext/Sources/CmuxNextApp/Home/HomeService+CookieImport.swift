import CmuxNextCookieImport

/// A Chief's cookie import ask, shown inline in Home (HomeHostView+CookieImport.swift).
extension HomeService {
    /// Shows `ask` in the Home Chief conversation the person sees now (the key window's first);
    /// false when no Chief conversation is on screen.
    func showCookieImport(_ ask: CookieImportAsk) -> Bool {
        let visible = askHosts.allObjects.filter { $0.showsChiefOnScreen }
        guard let host = visible.first(where: { $0.window?.isKeyWindow == true }) ?? visible.first else { return false }
        host.showCookieImport(ask)
        return true
    }
}
