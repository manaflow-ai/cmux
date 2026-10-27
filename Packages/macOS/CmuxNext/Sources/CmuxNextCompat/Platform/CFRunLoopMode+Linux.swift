// The run loop modes under the Darwin overlay's names, for code that adds observers and blocks to the main run
// loop or runs it (p15-oracle.md section H). Darwin's CoreFoundation overlay spells `kCFRunLoopCommonModes` and
// `kCFRunLoopDefaultMode` as `CFRunLoopMode.commonModes` and `.defaultMode`; swift-corelibs-foundation imports
// only the globals (static CFStrings, never nil). On Darwin this file is empty.

#if !canImport(Darwin)
public import CoreFoundation

extension CFRunLoopMode {
    /// `kCFRunLoopCommonModes`: the default mode and the tracking modes.
    public static var commonModes: CFRunLoopMode { kCFRunLoopCommonModes }

    /// `kCFRunLoopDefaultMode`.
    public static var defaultMode: CFRunLoopMode { kCFRunLoopDefaultMode }
}
#endif
