import Foundation
import WebKit

/// `input.setFiles { targetId, frameId, element, files: [{name, mimeType,
/// base64}] }`, as the CDP driver does it (cdp/choosers.rs): the files are
/// built in the page agent's world and set on the file input, which then
/// gets `input` and `change`. No Open panel is shown.
@MainActor
struct WebKitSetFiles {
    let driver: WebKitDriver

    private static let assignFiles = """
    const [input, files] = __handlesThenArgs(__handles, __args);
    const transfer = new DataTransfer();
    for (const f of files || []) {
      const bin = atob(f.base64 || "");
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      transfer.items.add(new File([bytes], f.name, { type: f.mimeType || "" }));
    }
    input.files = transfer.files;
    input.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
    return null;
    """

    func inputSetFiles(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try driver.target(params)
        let element = try params.string("element")
        let files = try params.array("files").map(\.foundationValue)
        let frame = try await driver.frameInfo(params, tab: tab, session: session)
        return try await driver.runInAgent(Self.assignFiles, handles: [element], args: [files], frame: frame, tab: tab)
    }
}
