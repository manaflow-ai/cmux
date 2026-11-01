import Foundation

/// Page scripts for `browser.page.drag` and `browser.page.upload` (browser
/// use thread, user 2026-10-19): an HTML5 drag from one element to another,
/// and files put into a file input, as synthetic events in the page.
extension BrowserPageScripts {
    /// Drags `selector` onto `target`: pointer and mouse down on the source,
    /// the HTML5 `dragstart`…`drop`…`dragend` sequence with one
    /// `DataTransfer`, and mouse moves to the target for pointer-driven
    /// lists. Answers the source as `at` and the target as `to`.
    static func drag(_ selector: String, to target: String) -> String {
        wrap(inputHelpers + measure + """
        const src = (() => { \(find(selector)) return el; })(); if (!src || src.error) return src;
        const dst = (() => { \(find(target)) return el; })(); if (!dst || dst.error) return dst;
        src.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const at = cmuxAt(src), to = cmuxAt(dst);
        const a = center(src), b = center(dst);
        let dt = null; try { dt = new DataTransfer(); } catch (_) {}
        const drag = (el, type, c) => { let ev; const init = { bubbles: true, cancelable: true, composed: true, clientX: c.x, clientY: c.y, dataTransfer: dt };
          try { ev = new DragEvent(type, init); } catch (_) { ev = new Event(type, init); }
          if (dt && ev.dataTransfer !== dt) { try { Object.defineProperty(ev, 'dataTransfer', { value: dt }); } catch (_) {} }
          el.dispatchEvent(ev); return ev; };
        pointer(src, 'pointerdown', a, 1); mouse(src, 'mousedown', a, 1, 1);
        drag(src, 'dragstart', a); drag(src, 'drag', a);
        pointer(dst, 'pointermove', b, 1); mouse(dst, 'mousemove', b, 1);
        drag(dst, 'dragenter', b); drag(dst, 'dragover', b);
        const drop = drag(dst, 'drop', b); drag(src, 'dragend', b);
        pointer(dst, 'pointerup', b, 0); mouse(dst, 'mouseup', b, 0, 1);
        return { value: { dropped: drop.defaultPrevented }, at, to };
        """)
    }

    /// Clicks `selector` to open the page's file chooser, as the person's click does: a file input (hidden
    /// ones too), its label, or a button whose handler opens one. Answers `{value: {fileInput}, at}`, or
    /// `{error, code}` for a missing or disabled element.
    static func openFileChooser(_ selector: String) -> String {
        wrap(find(selector) + """
        const W = (el.ownerDocument && el.ownerDocument.defaultView) || window;
        const fileInput = el instanceof W.HTMLInputElement && String(el.type).toLowerCase() === 'file';
        if (el.disabled) { return { error: 'Element is disabled: ' + raw, code: 'disabled' }; }
        const at = cmuxAt(el);
        if (!fileInput) { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); }
        el.click();
        return { value: { fileInput }, at };
        """)
    }

    /// Starts a chunked upload into a file input. The chunks are appended by
    /// ``uploadChunk`` and committed by ``finishUpload``; keeping the parts on
    /// the page avoids putting an arbitrarily large file in one evaluation.
    static func startUpload(_ selector: String, id: String, files: [(name: String, type: String)]) -> String {
        return wrap(find(selector) + """
        const W = (el.ownerDocument && el.ownerDocument.defaultView) || window;
        if (!(el instanceof W.HTMLInputElement) || String(el.type).toLowerCase() !== 'file') { return { error: 'Element is not a file input: ' + raw, code: 'not_file_input' }; }
        // One id names one upload: a second start with an active id is refused.
        if (\(uploadTargets).has(\(literal(id)))) { return { error: 'Upload id is already active', code: 'upload_id_in_use' }; }
        const uploads = el.__cmuxUploads || (el.__cmuxUploads = new Map());
        const state = { files: [\(files.map { "{ name: \(literal($0.name)), type: \(literal($0.type)), parts: [] }" }.joined(separator: ", "))], at: cmuxAt(el) };
        uploads.set(\(literal(id)), state);
        \(uploadTargets).set(\(literal(id)), el);
        return { value: { started: true }, at: state.at };
        """)
    }

    /// Appends one base64 chunk to the file at `index` in a started upload. `selector` is only for the
    /// caller's symmetry: the input is the one ``startUpload`` recorded for `id`.
    static func uploadChunk(_ selector: String, id: String, index: Int, base64: String) -> String {
        wrap(uploadTarget(id) + """
        const state = el && el.__cmuxUploads && el.__cmuxUploads.get(\(literal(id)));
        const file = state && state.files.at(\(index));
        if (!file) { return { error: 'Upload is not active', code: 'upload_not_started' }; }
        const bytes = Uint8Array.from(atob(\(literal(base64))), (c) => c.charCodeAt(0));
        file.parts.push(bytes);
        return { value: { appended: bytes.byteLength } };
        """)
    }

    /// Builds the files from their chunks, assigns them to the input and fires
    /// the same events as the old single-evaluation fallback.
    static func finishUpload(_ selector: String, id: String) -> String {
        wrap(uploadTarget(id) + """
        const state = el && el.__cmuxUploads && el.__cmuxUploads.get(\(literal(id)));
        if (!state) { return { error: 'Upload is not active', code: 'upload_not_started' }; }
        const W = (el.ownerDocument && el.ownerDocument.defaultView) || window;
        const dt = new W.DataTransfer();
        for (const f of state.files) dt.items.add(new W.File(f.parts, f.name, { type: f.type }));
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        el.files = dt.files;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.__cmuxUploads.delete(\(literal(id)));
        \(uploadTargets).delete(\(literal(id)));
        return { value: { files: Array.from(el.files).map((f) => f.name) }, at: cmuxAt(el) };
        """)
    }

    /// Discards a partially streamed upload after an evaluation or file read
    /// fails.
    static func cancelUpload(_ selector: String, id: String) -> String {
        wrap(uploadTarget(id) + """
        \(uploadTargets).delete(\(literal(id)));
        if (el && el.__cmuxUploads) el.__cmuxUploads.delete(\(literal(id)));
        return { value: { cancelled: true } };
        """)
    }

    /// The page's upload-id-to-input map. ``startUpload`` resolves the selector once and records its
    /// input here; chunks, completion and cleanup find the input by upload id, never by the selector,
    /// so a snapshot that moves an `eN` ref mid-upload cannot send them to another element.
    static let uploadTargets = "(window.__cmuxUploadTargets || (window.__cmuxUploadTargets = new Map()))"

    /// Binds `el` (and `cmuxAt`) to the input `startUpload` recorded for `id`, or `null` when none is.
    static func uploadTarget(_ id: String) -> String {
        "const el = \(uploadTargets).get(\(literal(id))) || null;\n" + measure
    }
}
