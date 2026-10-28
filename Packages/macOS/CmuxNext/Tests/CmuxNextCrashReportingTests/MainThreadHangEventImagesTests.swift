import Darwin
import Testing
@testable import CmuxNextCrashReporting

/// The hang event's Mach-O walk, now marked `unsafe` and bounded by the header's
/// `sizeofcmds`, still finds the loaded image of a code address: its UUID, its `__TEXT` range and its path.
struct MainThreadHangEventImagesTests {
    /// The address of `malloc`, in libsystem_malloc (the dyld shared cache on every supported macOS).
    private static func mallocAddress() -> UInt? {
        // SAFETY: dlsym reads the NUL-terminated copy of the name made for the call; RTLD_DEFAULT (-2) is a handle
        // value dlsym defines. The result is used as an integer address only.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc") else { return nil }
        return unsafe UInt(bitPattern: symbol)
    }

    @Test func aCodeAddressResolvesToItsLoadedImage() {
        guard let address = Self.mallocAddress() else {
            Issue.record("dlsym found no malloc")
            return
        }
        let images = MainThreadHangEvent.images(for: [address, address + 4])
        #expect(images.count == 1)
        #expect(images.first?.contains(address) == true)
        #expect(images.first?.uuid.count == 36)
        #expect(images.first?.path.hasSuffix(".dylib") == true)
    }

    @Test func anUnmappedAddressHasNoImage() {
        #expect(MainThreadHangEvent.images(for: [0, 8]).isEmpty)
    }
}
