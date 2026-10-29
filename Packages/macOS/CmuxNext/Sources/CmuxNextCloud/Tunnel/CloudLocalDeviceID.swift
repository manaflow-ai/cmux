public import CmuxNextWakeups
import Foundation

/// This Mac's install id on the main thread, kept once known, so a focus move does no file I/O.
/// The launch's read (``CloudDeviceIDSource``) has it; when that read failed, the next ask reads `device-id` again on
/// a files lane, so one failure to make it at launch never lasts the session. The main thread never reads the file
/// itself, except with no launch read of these paths (tests), where the first ask reads it.
///
/// ```swift
/// let deviceID = CloudLocalDeviceID(paths: paths, launch: environment.cloudDeviceID, work: work, mainWork: mainWork)
/// let id = try deviceID.id()   // never waits; `.notReadYet` while a read runs
/// ```
@MainActor
public final class CloudLocalDeviceID {
    /// The Cloud state whose id this is.
    public let paths: CloudPaths
    private let launch: CloudDeviceIDSource?
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    private var known: String?
    /// A read after the launch's failed one runs.
    private var rereading = false
    /// The last such read's failure; nil before one ended.
    private var rereadFailure: CloudDeviceIDError?

    /// - Parameters:
    ///   - paths: The Cloud state whose id this is.
    ///   - launch: The launch's read of it (`AppEnvironment.cloudDeviceID`); nil: read at the first ask (tests).
    ///   - work: The app's blocking-work lanes: a read after a failed one runs on its files lane.
    ///   - mainWork: The main-thread scheduler that read's result is posted on.
    public init(paths: CloudPaths, launch: CloudDeviceIDSource?, work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.paths = paths
        self.launch = launch
        self.work = work
        self.mainWork = mainWork
    }

    /// The id: ``CloudDeviceIDError/notReadYet`` while the launch's read runs; after a failed read, that failure
    /// while `device-id` is read again off the main thread, and the id once that read made it.
    public func id() throws(CloudDeviceIDError) -> String {
        if let known { return known }
        guard let launched = launch?.result(for: paths) else {
            let id = try paths.deviceIDResult().get()
            known = id
            return id
        }
        switch launched {
        case .success(let id):
            known = id
            return id
        case .failure(.notReadYet):
            throw CloudDeviceIDError.notReadYet
        case .failure(let failure):
            readAgain()
            throw rereadFailure ?? failure
        }
    }

    /// One read of `device-id` on the files lane at a time; its id is kept, its failure is the next ask's error.
    private func readAgain() {
        guard !rereading else { return }
        rereading = true
        let paths = paths
        work.run(.userVisible, mayBlock: .files) { paths.deviceIDResult() }
            .reply(on: mainWork, class: .visible, owner: "Cloud.deviceID") { [weak self] result in
                guard let self else { return }
                rereading = false
                switch result {
                case .success(let id): known = id
                case .failure(let failure): rereadFailure = failure
                }
            }
    }
}
