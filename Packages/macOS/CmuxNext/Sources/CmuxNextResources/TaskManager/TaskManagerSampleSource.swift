import Foundation

/// Takes one Task Manager sample. The App reads every tab and daemon; tests
/// pass synthetic samples. Called only while a Task Manager page is open.
public protocol TaskManagerSampleSource: AnyObject {
    @MainActor func sample() async -> TaskManagerSampleSet
}
