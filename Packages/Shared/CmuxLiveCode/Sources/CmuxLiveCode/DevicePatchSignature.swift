// Who may publish a patch to an iPhone (ios-dev-channels step 4; cmux#13742 for the Mac): a cmux Dev
// app on a device loads a patch only when it is signed, with a real (not ad hoc) signature, by the
// app's own team. The Mac signs it with its Apple Development identity (scripts/live-code/patch.py
// --sign, scripts/live-code/ios-device.sh) and sends it over the link (cmux-mobile-host live_code.rs).
//
// iOS has no SecStaticCode, and it needs none: the kernel maps only code whose signature it
// validates, and in a third-party app only code of the app's own team (library validation is always
// on). This check reads the patch's own code signature (its CodeDirectory's team, its flags and its
// CMS blob) and refuses a stranger's or an ad hoc patch early, with a reason in the log, instead of
// a bare dlopen failure. It reads the bytes only: nothing here trusts the file, and the kernel's
// check of the mapped code stays the one that counts.
//
// Only a DEBUG build has it on iOS (LiveEngine.swift): a Release binary holds none of it.
#if os(macOS) || DEBUG
import Foundation

/// The code signature of a Mach-O file, as far as the patch check needs it.
struct MachOCodeSignature: Equatable, Sendable {
    /// The CodeDirectory's team, nil when it names none.
    var teamID: String?
    /// The CodeDirectory's ad hoc flag (`CS_ADHOC`).
    var adhoc: Bool
    /// A CMS signature blob with content: a certificate signed it.
    var signed: Bool

    static let mhMagic64: UInt32 = 0xFEED_FACF
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let cpuARM64: UInt32 = 0x0100_000C
    static let lcCodeSignature: UInt32 = 0x1D
    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    static let blobWrapperMagic: UInt32 = 0xFADE_0B01
    static let slotCodeDirectory: UInt32 = 0
    static let slotSignature: UInt32 = 0x10000
    static let csAdhoc: UInt32 = 0x2
    /// The first CodeDirectory version with a team offset.
    static let teamVersion: UInt32 = 0x20200

    /// Reads a thin 64-bit Mach-O, or the arm64 slice of a fat one. Throws when the file has no
    /// readable code signature.
    static func read(_ data: Data) throws -> MachOCodeSignature {
        let bytes = [UInt8](data)
        var base = 0
        if bytes.count >= 8, be32(bytes, 0) == fatMagic {
            let count = Int(be32(bytes, 4))
            var found: Int?
            for index in 0..<min(count, 32) {
                let at = 8 + index * 20
                guard at + 20 <= bytes.count else { break }
                if be32(bytes, at) == cpuARM64 { found = Int(be32(bytes, at + 8)) }
            }
            guard let found else { throw LiveCodeError.notOurTeam("a fat file with no arm64 slice") }
            base = found
        }
        guard base + 32 <= bytes.count, le32(bytes, base) == mhMagic64 else {
            throw LiveCodeError.notOurTeam("not a 64-bit Mach-O file")
        }
        let ncmds = Int(le32(bytes, base + 16))
        var at = base + 32
        var signature: (offset: Int, size: Int)?
        for _ in 0..<min(ncmds, 4096) {
            guard at + 8 <= bytes.count else { break }
            let cmd = le32(bytes, at), size = Int(le32(bytes, at + 4))
            guard size >= 8 else { break }
            if cmd == lcCodeSignature, at + 16 <= bytes.count {
                signature = (base + Int(le32(bytes, at + 8)), Int(le32(bytes, at + 12)))
            }
            at += size
        }
        guard let signature, signature.size >= 12, signature.offset + signature.size <= bytes.count else {
            throw LiveCodeError.notOurTeam("no code signature")
        }
        let blob = Array(bytes[signature.offset..<(signature.offset + signature.size)])
        guard be32(blob, 0) == superBlobMagic else { throw LiveCodeError.notOurTeam("a malformed code signature") }
        let count = Int(be32(blob, 8))
        var directory: Int?
        var signed = false
        for index in 0..<min(count, 64) {
            let entry = 12 + index * 8
            guard entry + 8 <= blob.count else { break }
            let type = be32(blob, entry), offset = Int(be32(blob, entry + 4))
            guard offset + 8 <= blob.count else { continue }
            if type == slotCodeDirectory, be32(blob, offset) == codeDirectoryMagic { directory = offset }
            if type == slotSignature, be32(blob, offset) == blobWrapperMagic, be32(blob, offset + 4) > 8 { signed = true }
        }
        guard let directory, directory + 44 <= blob.count else { throw LiveCodeError.notOurTeam("no CodeDirectory") }
        let version = be32(blob, directory + 8)
        let flags = be32(blob, directory + 12)
        var team: String?
        if version >= teamVersion, directory + 52 <= blob.count {
            let offset = Int(be32(blob, directory + 48))
            if offset > 0, directory + offset < blob.count {
                let start = directory + offset
                let end = blob[start...].firstIndex(of: 0) ?? blob.count
                team = String(decoding: blob[start..<end], as: UTF8.self)
            }
        }
        return MachOCodeSignature(teamID: team, adhoc: flags & csAdhoc != 0, signed: signed)
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

/// Which patches an iPhone app's engine loads.
public enum LiveCodeDeviceSigner: Equatable, Sendable {
    /// Any patch, ad hoc included: the iOS Simulator, whose app is a macOS process (ios-sim.sh).
    case any
    /// Only one signed by this team, not ad hoc: a cmux Dev app on a device.
    case team(String)
    /// Every patch is refused, for this reason (the app's own team is unreadable).
    case refuseAll(String)

    /// The running app's: `.any` in the Simulator, else its own executable's team.
    public static func running() -> LiveCodeDeviceSigner {
        #if targetEnvironment(simulator)
        return .any
        #else
        guard let path = Bundle.main.executablePath, let data = FileManager.default.contents(atPath: path) else {
            return .refuseAll("the app's executable is unreadable")
        }
        return of(app: data)
        #endif
    }

    /// The signer an app with this executable gets.
    static func of(app executable: Data) -> LiveCodeDeviceSigner {
        do {
            let signature = try MachOCodeSignature.read(executable)
            guard let team = signature.teamID, isTeamID(team), !signature.adhoc else {
                return .refuseAll("the app's signature names no team")
            }
            return .team(team)
        } catch {
            return .refuseAll("the app's own signature is unreadable: \(error)")
        }
    }

    /// A team ID is ten capitals and digits.
    static func isTeamID(_ id: String) -> Bool {
        id.utf8.count == 10 && id.utf8.allSatisfy {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        }
    }
}

enum DevicePatchSignature {
    /// Throws unless the patch at `path` may load under `signer`. Off the main thread: it reads the file.
    static func check(_ path: String, signer: LiveCodeDeviceSigner) throws {
        switch signer {
        case .any:
            return
        case .refuseAll(let why):
            throw LiveCodeError.notOurTeam(why)
        case .team(let team):
            guard let data = FileManager.default.contents(atPath: path) else {
                throw LiveCodeError.notOurTeam("the patch is unreadable")
            }
            try check(data, team: team)
        }
    }

    static func check(_ patch: Data, team: String) throws {
        let signature = try MachOCodeSignature.read(patch)
        guard !signature.adhoc, signature.signed else {
            throw LiveCodeError.notOurTeam("signed ad hoc (patch.py --sign with this Mac's Apple Development identity)")
        }
        guard signature.teamID == team else {
            throw LiveCodeError.notOurTeam("team \(team) required, the patch's is \(signature.teamID ?? "none")")
        }
    }
}

/// Where Swift live code may run on an iPhone: only in a DEBUG build (the only one that compiles
/// this), only in cmux Dev or a tagged dev build (`dev.cmux.mobile.*`), and only when the launch
/// asked for it (`CMUX_LIVE_CODE_LINK=1`, which scripts/live-code/ios-device.sh run passes).
public struct LiveCodeDeviceGate {
    public init() {}
    /// The dev bundle ids' prefix (cmux Dev is `dev.cmux.mobile.dev`).
    public static let bundlePrefix = "dev.cmux.mobile."
    /// The launch variable that turns it on.
    public static let environmentKey = "CMUX_LIVE_CODE_LINK"

    public static func allows(bundleID: String?, environment: [String: String]) -> Bool {
        guard let bundleID, bundleID.hasPrefix(bundlePrefix), bundleID.count > bundlePrefix.count else { return false }
        return environment[environmentKey] == "1"
    }

    /// The live folder in the app's own container: the link feed (CmuxMobileLive
    /// `LiveCodeLinkFeed`, which keeps the same path) writes each patch there and the engine watches it.
    public static func folder() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-live-code/live", isDirectory: true)
    }
}
#endif
