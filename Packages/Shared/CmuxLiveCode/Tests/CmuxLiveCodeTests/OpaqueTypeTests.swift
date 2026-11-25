import Foundation
import MachO
import Testing
@testable import CmuxLiveCode

/// A patch whose `some View` changed type is refused (Interposer.opaqueTypeChanges): the check reads
/// an opaque type descriptor's underlying type by name. These samples are public so their
/// descriptors are external symbols of this test image, as an app's are in a live code build.
public func liveCodeOpaqueSampleInt() -> some Equatable { 1 }
public func liveCodeOpaqueSampleArray() -> some Collection { [Optional("a")] }

struct OpaqueTypeTests {
    /// This test image's opaque type descriptors whose name has `marker` (Swift mangling shortens
    /// a word the module name already has, so "liveCode" is not spelled out in the symbol).
    private func descriptors(_ marker: String) throws -> [UnsafeRawPointer] {
        var info = Dl_info()
        #expect(dladdr(#dsohandle, &info) != 0)
        let base = try #require(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        let index = try #require((0..<_dyld_image_count()).first { _dyld_get_image_header($0) == UnsafePointer(base) })
        return Interposer.symbols(header: UnsafePointer(base), slide: _dyld_get_image_vmaddr_slide(index), code: false)
            .filter { $0.0.contains(marker) && $0.0.hasSuffix("QOMQ") }.map(\.1)
    }

    @Test func anOpaqueResultNamesItsUnderlyingType() throws {
        let ints = try descriptors("OpaqueSampleIntQ")
        #expect(ints.count == 1)
        #expect(ints.compactMap { Interposer.underlyingTypeNames($0) } == [["Swift.Int"]])
        let arrays = try descriptors("OpaqueSampleArrayQ")
        #expect(arrays.compactMap { Interposer.underlyingTypeNames($0) } == [["Swift.Array<Swift.Optional<Swift.String>>"]])
    }
}
