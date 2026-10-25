import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings

/// `browser.page.upload` through the page's own file chooser (`BrowserAgentFiles`): the files are offered
/// to the tab's next chooser, the upload script clicks the element as the person (an agent gesture, so
/// the page may open a chooser), and the chooser takes the real files, any size.
extension AppBrowserPage {
    static func upload(_ upload: BrowserPageUpload, page: any BrowserTab) async throws -> JSONValue {
        // A page with no chooser path of its own: the service puts the files in through the page instead.
        guard let chooser = page as? any BrowserAgentFileChoosing else { return ["chooser": "unsupported"] }
        var answer: JSONValue = .null
        let outcome = try await chooser.agentFiles.offer(upload.files, within: upload.within) {
            do {
                answer = await json(try await page.evaluate(upload.script, world: .page, gesture: .agent))
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
            // The element was missing or refused: no chooser can open.
            return answer["error"] == nil
        }
        let chooserAnswer: String = switch outcome {
        case .chosen: "chosen"
        case .withdrawn: "withdrawn"
        case .refused(let refusal): refusal.rawValue
        }
        return ["value": answer, "chooser": .string(chooserAnswer)]
    }
}
