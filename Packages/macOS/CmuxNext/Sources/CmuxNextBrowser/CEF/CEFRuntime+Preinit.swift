extension CEFRuntime {
    /// Options the shim takes before `cmux_shim_initialize` from the start's prepared inputs and the engine's
    /// features: Google Chrome's native messaging hosts after cmux's own, and a page's alert, confirm, prompt
    /// and HTTP sign-in in cmux's dialogs (feature `chromiumPageDialogs`, ``CEFPageDialogs``), which the shim
    /// needs before initialize to turn Chrome's login prompt off.
    func applyPreinit(_ shim: CEFShimLibrary, nativeMessagingFolders: [CEFNativeMessaging.Folder]) {
        for folder in nativeMessagingFolders {
            _ = shim.addNativeMessagingDir(folder.path, folder.isUserLevel ? 1 : 0)
        }
        if asksPageDialogs { shim.setPageDialogs(1) }
    }
}
