// The live folder's engine: a running app takes new code for its Swift functions without a rebuild
// or a relaunch (docs/cmux-next/live-code.md). A patch is edited files compiled against this build
// and linked as a dylib (scripts/live-code/patch.py); dropped into the live folder, it is loaded,
// every function it defines that the app also defines is repointed to the new one (Interposer.swift),
// and the app's `redraw` runs. It works only in a live code build (scripts/live-code/build.sh for the
// macOS app, scripts/live-code/ios-sim.sh for the iPhone app in the iOS Simulator).
//
// The live folder is the whole interface, so `cmux live-code` (and its MCP tools) can repair the
// app when its UI is wedged: a new `*.dylib` applies, a new `*.rollback` undoes the newest patch,
// a new `*.rollback-all` undoes them all, and the app keeps `status.json` (what is applied) and
// `live-code.log` there. All of it runs on the engine actor, never on the main thread; only the
// redraw after a change is the app's, which sends it to the main thread without waiting for it.
// Shipped iPhone builds (Release, TestFlight, App Store) compile none of it: on iOS only a DEBUG
// build (Debug, or ios-sim.sh's Demo with DEBUG) has the engine, so a Release binary holds no
// loader, no interposer and no private dyld symbol name. The macOS app keeps it in every build.
// The engine repoints Mach-O symbols (Interposer.swift), so it needs MachO; the live folder's disk
// side (LiveFolder.swift) is POSIX and also builds, and is tested, on Linux.
#if canImport(MachO) && (os(macOS) || DEBUG)
import Darwin
import Foundation

/// The live folder's changes, applied one at a time off the main thread.
public actor LiveEngine {
    public let folder: LiveFolder
    private var source: (any DispatchSourceFileSystemObject)?
    private var seen = Set<String>()
    /// Each replaced function's newest code (Interposer.apply).
    private var current: [String: UnsafeRawPointer] = [:]
    /// The applied patches, oldest first: an undo takes the last one off.
    private var applied: [(patch: Interposer.Applied, record: LivePatchRecord)] = []
    private var generation = 0
    private var lastError: String?
    /// After each applied or undone patch, with the new generation: the app redraws (on its main
    /// thread, never waited for here).
    private let redraw: @Sendable (Int) -> Void
    #if os(macOS)
    /// Who signed this app, read once from its own code signature; nil in Debug and bench, which load
    /// any patch.
    private let signer: LiveCodeSigner?

    /// `signer` is nil in Debug and bench, which load any patch; the app decides, since only its own
    /// compilation conditions say which build it is.
    public init(folder: LiveFolder, signer: LiveCodeSigner?, redraw: @escaping @Sendable (Int) -> Void) {
        self.folder = folder
        self.signer = signer
        self.redraw = redraw
    }
    #else
    /// Which patches load: `.any` in the Simulator, the app's own team on a device.
    private let deviceSigner: LiveCodeDeviceSigner

    /// The iOS Simulator's live code build is a Debug build: it loads any patch, ad hoc included.
    public init(folder: LiveFolder, redraw: @escaping @Sendable (Int) -> Void) {
        self.init(folder: folder, deviceSigner: .any, redraw: redraw)
    }

    /// A cmux Dev app on a device: only a patch signed by its own team, not ad hoc, loads
    /// (DevicePatchSignature.swift; `LiveCodeDeviceSigner.running()` reads the team).
    public init(folder: LiveFolder, deviceSigner: LiveCodeDeviceSigner, redraw: @escaping @Sendable (Int) -> Void) {
        self.folder = folder
        self.deviceSigner = deviceSigner
        self.redraw = redraw
    }
    #endif

    /// Opens and watches the folder; false when it cannot.
    public func start() -> Bool {
        guard let opened = folder.open() else {
            folder.append("live code: cannot watch \(folder.url.path)")
            return false
        }
        // What is already there belongs to an earlier run, maybe of an older build: never load it.
        seen = Set(opened.names)
        source = folder.watch(opened.descriptor) { [weak self] names in
            guard let self else { return }
            Task { await self.found(names) }
        }
        say("watching \(folder.url.path) dyld_dynamic_interpose=\(Interposer.hasDynamicInterpose ? "yes" : "no, rebind only")")
        #if os(macOS)
        switch signer {
        case .noTeam?:
            say("this app is unsigned (its signature names no team): any validly signed patch loads, ad hoc included")
        case .unreadable(let detail)?:
            say("this app's own signature is unreadable (\(detail)): every patch is refused")
        case .unprotected(let team, let why)?:
            say("this app (team \(team)) runs without library validation (\(why)): every patch is refused")
        case .team?, nil:
            break
        }
        #else
        switch deviceSigner {
        case .any: break
        case .team(let team): say("only patches signed by team \(team), not ad hoc, load")
        case .refuseAll(let why): say("\(why): every patch is refused")
        }
        #endif
        writeStatus()
        return true
    }

    /// The folder's names after a change: each new one is handled once, in name order.
    func found(_ names: [String]) {
        for name in names where !seen.contains(name) {
            seen.insert(name)
            if name.hasSuffix(".rollback-all") {
                undo(name, all: true)
            } else if name.hasSuffix(".rollback") {
                undo(name, all: false)
            } else {
                apply(name)
            }
        }
    }

    private func apply(_ name: String) {
        let started = Date()
        var phases = Interposer.Phases()
        do {
            // The check and the load read one private copy, never the shared folder's file twice.
            let copy = try folder.privateCopy(name)
            defer { try? FileManager.default.removeItem(at: copy) }
            phases.end("copy")
            #if os(macOS)
            // Outside Debug and bench, only a patch signed by this app's team loads, or, for an
            // unsigned app, any validly signed one (cmux#13742).
            if let signer {
                try PatchSignature.check(copy.path, app: signer)
            }
            #else
            try DevicePatchSignature.check(copy.path, signer: deviceSigner)
            #endif
            phases.end("sign")
            let handle = try Interposer.load(copy.path)
            phases.end("open")
            let patched = try Interposer.apply(handle: handle, dylib: copy.path, current: &current, phases: &phases)
            let sidecar = folder.sidecar(name)
            let record = LivePatchRecord(name: name, commit: sidecar?.commit, files: sidecar?.files,
                                         functions: patched.after.count, appliedAt: Date().timeIntervalSince1970)
            applied.append((patched, record))
            let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
            // Harnesses read up to at=; the phases after it say where load_ms went, and images= how
            // many images this process holds (each applied patch stays loaded), so a load that grows
            // with them names its phase (the duress run on cmux#56326: 13 ms at 0 patches, 124 at 6000).
            changed("applied \(name) functions=\(record.functions) load_ms=\(ms) at=\(Date().timeIntervalSince1970) \(phases.line) images=\(_dyld_image_count())")
        } catch {
            refused(name, error)
        }
    }

    /// The code from before the newest patch (or before every patch) runs again, in this process.
    private func undo(_ name: String, all: Bool) {
        let started = Date()
        guard !applied.isEmpty else {
            refused(name, LiveCodeError.nothingToUndo)
            return
        }
        var count = 0
        do {
            for _ in 0..<(all ? applied.count : 1) {
                guard let last = applied.last else { break }
                count += try Interposer.revert(last.patch, current: &current)
                applied.removeLast()
            }
            let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
            changed("rolled back \(name) functions=\(count) rollback_ms=\(ms) left=\(applied.count) at=\(Date().timeIntervalSince1970)")
        } catch {
            refused(name, error)
        }
    }

    private func changed(_ line: String) {
        generation += 1
        lastError = nil
        say(line)
        writeStatus()
        // Never waits on the main thread: a wedged one still gets the undo, and redraws when it can.
        redraw(generation)
    }

    private func refused(_ name: String, _ error: any Error) {
        lastError = "\(name): \(error)"
        say("\(name) refused: \(error)")
        writeStatus()
    }

    private func say(_ line: String) {
        NSLog("cmux live code: %@", line)
        folder.append("live code: \(line)")
    }

    private func writeStatus() {
        let status = LiveStatus(
            pid: getpid(), executable: Bundle.main.executablePath, bundleID: Bundle.main.bundleIdentifier, teamSignedOnly: teamSignedOnly,
            folder: folder.url.path, generation: generation, patches: applied.reversed().map(\.record),
            lastError: lastError, updatedAt: Date().timeIntervalSince1970)
        folder.writeStatus(status)
    }

    private var teamSignedOnly: Bool {
        #if os(macOS)
        switch signer {
        case .team?, .unprotected?, .unreadable?: true
        case .noTeam?, nil: false
        }
        #else
        deviceSigner != .any
        #endif
    }
}

/// The live folder's event side: O_EVTONLY and a vnode dispatch source are Darwin's.
extension LiveFolder {
    /// Creates the folder and opens it for events; with the names it holds now.
    func open() -> (descriptor: Int32, names: [String])? {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        return descriptor >= 0 ? (descriptor, entries()) : nil
    }

    /// Calls `changed` on a utility queue with the folder's names after each change.
    func watch(_ descriptor: Int32, _ changed: @escaping @Sendable ([String]) -> Void) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global(qos: .utility))
        source.setEventHandler { changed(entries()) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
#endif
