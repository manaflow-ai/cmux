import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Testing
@testable import CmuxNextPhone

/// The phone module's pointer sites after the strict-memory-safety pass.
/// Private Objective-C calls are made only when the method's type encoding has the shape the
/// call spells; Indigo messages are freed exactly once; Core Media and VideoToolbox pointers
/// stay inside the memory their `// SAFETY:` argument names. Run under ASan
/// (`--sanitize=address`): an out-of-bounds, dangling or double-freed access fails the run.
@Suite struct PhoneMemorySafetyTests {
    // MARK: Type encodings

    @Test func methodEncodingsParse() throws {
        let getter = try #require(PrivateSignature(encoding: "@16@0:8"))
        #expect(getter.returns == "@" && getter.arguments.isEmpty)
        let register = try #require(PrivateSignature(encoding: "v56@0:8@16@24@?32@?40@?48"))
        #expect(register.returns == "v" && register.arguments == ["@", "@", "@?", "@?", "@?"])
        #expect(register.matches(returns: .void, arguments: Array(repeating: .object, count: 5)))
        let lookup = try #require(PrivateSignature(encoding: "I32@0:8@16^@24"))
        #expect(lookup.matches(returns: .integer(bytes: 4), arguments: [.object, .pointer]))
        #expect(!lookup.matches(returns: .integer(bytes: 8), arguments: [.object, .pointer]))
        let size = try #require(PrivateSignature(encoding: "{CGSize=dd}16@0:8"))
        #expect(size.matches(returns: .structure("CGSize"), arguments: []))
        #expect(!size.matches(returns: .object, arguments: []))
        // Qualifiers, extended object and block types, and a Core Foundation reference.
        #expect(try #require(PrivateSignature(encoding: "Vv16@0:8")).returns == "v")
        #expect(try #require(PrivateSignature(encoding: #"@"NSString"16@0:8"#)).matches(returns: .object, arguments: []))
        #expect(try #require(PrivateSignature(encoding: "v24@0:8@?<v@?>16")).matches(returns: .void, arguments: [.object]))
        #expect(try #require(PrivateSignature(encoding: "^{__IOSurface=}16@0:8")).matches(returns: .object, arguments: []))
        #expect(try #require(PrivateSignature(encoding: "v28@0:8r^{IndigoMessage=I}16B24")).arguments == ["^{IndigoMessage=I}", "B"])
        // An argument count that differs is no match.
        #expect(!getter.matches(returns: .object, arguments: [.object]))
    }

    @Test(arguments: ["", "@", "@16@0", "{CGSize=dd16@0:8", "q16:0@8"])
    func malformedEncodingsAreRefused(encoding: String) {
        #expect(PrivateSignature(encoding: encoding) == nil)
    }

    // MARK: Private calls

    /// Each shape reads what the method returns, through the registers it uses.
    @Test func privateCallsReadEachShape() {
        let fixture = PrivateCallsFixture()
        #expect(privateObject(fixture, "name") as? String == "phone")
        #expect(privateNumber(fixture, "scale") == 3)
        #expect(privateNumber(fixture, "smallScale") == 2)
        #expect(privateNumber(fixture, "count") == -7)
        #expect(privateNumber(fixture, "narrow") == -5)
        #expect(privateNumber(fixture, "flag") == 1)
        #expect(privateSize(fixture, "size") == CGSize(width: 393, height: 852))
        #expect(privateVoid(fixture, "touch"))
        #expect(privateVoid(fixture, "take:", "taken" as NSString))
        #expect(fixture.touched == 1 && fixture.taken == "taken")
        let action = privateAction(fixture, "touch")
        action?()
        action?()
        #expect(fixture.touched == 3)
    }

    /// A selector whose shape is not the one asked for is not called. Before the encoding check,
    /// reading `scale` (a Double, in d0) as an object took whatever x0 held and retained it.
    @Test func aSelectorOfAnotherShapeIsNotCalled() {
        let fixture = PrivateCallsFixture()
        #expect(privateObject(fixture, "scale") == nil)
        #expect(privateObject(fixture, "size") == nil)
        #expect(privateNumber(fixture, "name") == nil)
        #expect(privateNumber(fixture, "size") == nil)
        #expect(privateSize(fixture, "scale") == nil)
        #expect(!privateVoid(fixture, "name"))
        #expect(!privateVoid(fixture, "touch", "x" as NSString))
        #expect(!privateVoid(fixture, "take:"))
        #expect(privateObject(fixture, "missing") == nil)
        #expect(fixture.touched == 0)
    }

    /// A receiver that answers through forwarding (`forwardingTargetForSelector:`, as a
    /// CoreSimulator proxy may) has no Method for the selector on its class; the call goes
    /// through the runtime's forwarding entry with the forwarded method's signature.
    @Test func forwardedSelectorsAreCalled() {
        let proxy = ForwardingFixture()
        #expect(privateObject(proxy, "name") as? String == "phone")
        #expect(privateNumber(proxy, "scale") == 3)
        #expect(privateNumber(proxy, "count") == -7)
        #expect(privateVoid(proxy, "touch"))
        #expect(privateVoid(proxy, "take:", "forwarded" as NSString))
        #expect(privateObjectWithError(proxy, "defaultDeviceSetWithError:") as? String == "set")
        #expect(proxy.inner.touched == 1 && proxy.inner.taken == "forwarded")
        // The shape check holds for a forwarded selector too; a structure return is refused.
        #expect(privateObject(proxy, "scale") == nil)
        #expect(!privateVoid(proxy, "touch", "x" as NSString))
        #expect(privateSize(proxy, "size") == nil)
        #expect(privateObject(proxy, "missing") == nil)
        #expect(proxy.inner.touched == 1)
    }

    /// `methodSignatureForSelector:`'s type strings read as the same signature the method's
    /// own encoding gives (the source for a selector forwarded through `forwardInvocation:`).
    @Test(arguments: ["name", "scale", "count", "size", "touch", "take:", "defaultDeviceSetWithError:"])
    func messageSignaturesMatchMethodEncodings(name: String) throws {
        let fixture = PrivateCallsFixture()
        let encoded = try #require(PrivateMethod(fixture, name)).signature
        #expect(PrivateMethod.messageSignature(privateSelector(name), of: fixture) == encoded)
    }

    @Test func aMissingSelectorHasNoMessageSignature() {
        #expect(PrivateMethod.messageSignature(privateSelector("missing"), of: PrivateCallsFixture()) == nil)
    }

    /// The error out-parameter is written (or not) inside the local it points to.
    @Test func errorOutParametersStayLocal() {
        let fixture = PrivateCallsFixture()
        #expect(privateObjectWithError(fixture, "defaultDeviceSetWithError:") as? String == "set")
        #expect(privateObjectWithError(fixture, "failingWithError:") == nil)
        let shared = privateClassObjectWithError(PrivateCallsFixture.self, "sharedForDirectory:error:", "/dev" as NSString)
        #expect(shared as? String == "/dev")
        #expect(privateClassObjectWithError(PrivateCallsFixture.self, "missing:error:", "/dev" as NSString) == nil)
    }

    /// alloc + init yields one owned instance: released when the caller lets go, no extra +1.
    @Test func privateInstancesAreOwnedOnce() throws {
        weak var released: NSObject?
        try autoreleasepool {
            let made = try #require(privateInstance(of: PrivateInitFixture.self, initializer: "initWithDevice:error:", "sim" as NSString))
            #expect((made as? PrivateInitFixture)?.device == "sim")
            released = made
        }
        #expect(released == nil)
        #expect(privateInstance(of: PrivateInitFixture.self, initializer: "initWithDevice:error:", NSNull()) == nil)
        #expect(privateInstance(of: PrivateInitFixture.self, initializer: "initWithMissing:error:", "sim" as NSString) == nil)
    }

    // MARK: C symbols and Indigo messages

    private typealias GetPID = @convention(c) () -> Int32

    @MainActor @Test func exportedFunctionsResolveByName() {
        let runtime = SimulatorKitRuntime(developerDirectory: "/nonexistent")
        #expect(runtime.function("getpid", as: GetPID.self)?() == ProcessInfo.processInfo.processIdentifier)
        #expect(runtime.function("cmux_no_such_symbol_p10", as: GetPID.self) == nil)
    }

    /// A handed-off message is the builder's block, given up once: the test frees it, so a
    /// second free by the message would be a double free under ASan.
    @Test func indigoMessagesAreHandedOffOnce() {
        // SAFETY: a fresh 16-byte block, owned by nobody else.
        guard let block = unsafe malloc(16) else {
            Issue.record("malloc gave no block")
            return
        }
        // SAFETY: `block` is malloc'd and owned by nobody else; the message takes it.
        let message = unsafe IndigoMessage(block)
        // SAFETY: the message gives up its block; this test now owns it.
        let handed = unsafe message.handOff()
        // SAFETY: compares the two addresses only.
        let same = unsafe handed == block
        #expect(same)
        // SAFETY: the block was handed off, so this is its only free.
        unsafe free(handed)
        // SAFETY: a message of nil owns nothing.
        let none = unsafe IndigoMessage(nil).handOff() == nil
        #expect(none)
    }

    // MARK: Big-endian bytes

    @Test func bigEndianBytesNeedNoPointer() {
        var bytes = Data()
        bytes.appendBigEndian(UInt32(0x0102_0304))
        bytes.appendBigEndian(UInt8(0xAB))
        bytes.appendBigEndian(Int16(-2))
        bytes.appendBigEndian(UInt64(42))
        #expect(Array(bytes) == [1, 2, 3, 4, 0xAB, 0xFF, 0xFE, 0, 0, 0, 0, 0, 0, 0, 42])
        let unit = SurfaceSourceWire.accessUnit(idr: true, captureMicros: 0x0102_0304_0506_0708, annexB: Data([9]))
        #expect(Array(unit) == [2, 0, 0, 0, 10, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    // MARK: VideoToolbox and Core Media

    /// A real encode walks every Core Video, VideoToolbox and Core Media pointer site: the
    /// IOSurface wrap, the pool buffer, the parameter sets and the block copy (SurfaceFrameEncoder),
    /// then the Android path's format description and AVCC sample built from those sets.
    @MainActor @Test func anEncodedFrameBecomesADisplayImmediatelySample() async throws {
        let surface = try #require(IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]))
        let encoder = try #require(SurfaceFrameEncoder(sourceWidth: 64, sourceHeight: 64))
        let encoded: (data: Data, keyframe: Bool)? = await withCheckedContinuation { done in
            encoder.encode(surface, forceKeyframe: true) { done.resume(returning: $0) }
            encoder.finish()
        }
        let frame = try #require(encoded)
        #expect(frame.keyframe)
        var parser = AnnexBParser()
        var units = parser.append(frame.data)
        if let last = parser.flush() { units.append(last) }
        let sps = try #require(units.first { H264Unit($0).kind == .sps })
        let pps = try #require(units.first { H264Unit($0).kind == .pps })
        let idr = try #require(units.first { H264Unit($0).kind == .keyframe })

        let format = try #require(AndroidFrameAssembler.format(sps: sps, pps: pps))
        #expect(AndroidFrameAssembler.format(sps: Data(), pps: pps) == nil)
        let sample = try #require(AndroidFrameAssembler.sample(idr, format: format))
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        #expect(CMBlockBufferGetDataLength(block) == 4 + idr.count)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        #expect(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
        // The sample's bytes read back as the same Annex B unit.
        #expect(SurfaceFrameEncoder.annexB(sample, keyframe: false) == Data([0, 0, 0, 1]) + idr)
    }
}

/// An Objective-C object with one method of each shape the phone module sends.
private final class PrivateCallsFixture: NSObject {
    @objc var name: NSString = "phone"
    @objc var scale: Double = 3
    @objc var smallScale: Float = 2
    @objc var count: Int = -7
    @objc var narrow: Int32 = -5
    @objc var flag = true
    @objc var size = CGSize(width: 393, height: 852)
    private(set) var touched = 0
    private(set) var taken: NSString?

    @objc func touch() { touched += 1 }

    @objc func take(_ value: NSString) { taken = value }

    @objc(defaultDeviceSetWithError:) func defaultDeviceSet() throws -> NSString { "set" }

    @objc(failingWithError:) func failing() throws -> NSString { throw CocoaError(.featureUnsupported) }

    @objc(sharedForDirectory:error:) class func shared(directory: NSString) throws -> NSString { directory }
}

/// An object that answers PrivateCallsFixture's selectors only by forwarding them to one.
private final class ForwardingFixture: NSObject {
    let inner = PrivateCallsFixture()

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || inner.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        inner.responds(to: aSelector) ? inner : super.forwardingTarget(for: aSelector)
    }
}

/// A class made the way SimulatorKit's legacy HID client is: alloc, then a throwing initializer.
private final class PrivateInitFixture: NSObject {
    let device: NSString

    @objc(initWithDevice:error:) init(device: AnyObject) throws {
        guard let device = device as? NSString else { throw CocoaError(.featureUnsupported) }
        self.device = device
        super.init()
    }
}
