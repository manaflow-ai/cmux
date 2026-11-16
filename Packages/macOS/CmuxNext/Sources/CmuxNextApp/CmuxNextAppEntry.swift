/// The app's one C entry point, which `App/main.swift` (the stub executable) calls.
///
/// The app's code is `CmuxNextApp.framework` (Package.swift, CMUX-629): the
/// framework exports only this symbol, so the stub binds one name and dead code
/// stripping keeps only what ``CmuxNextApp/main()`` reaches.
@_cdecl("cmux_next_app_main")
public func cmuxNextAppMain() {
    CmuxNextApp.shared.main()
}
