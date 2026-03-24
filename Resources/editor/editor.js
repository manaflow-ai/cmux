// cmux Editor — single-file Monaco editor
// Swift injects Monaco paths via window.cmux.initMonaco(vsPath, cssPath)

(function () {
    'use strict';

    let editor = null;
    let monacoInstance = null;
    let currentFilePath = null;
    let originalContent = '';
    let isDirty = false;
    let requestCounter = 0;
    const pendingRequests = new Map();

    // ── Swift Bridge ───────────────────────────────────────────────────
    window.cmux = {
        handleResponse(requestId, data) {
            const p = pendingRequests.get(requestId);
            if (!p) return;
            pendingRequests.delete(requestId);
            if (typeof data === 'string') {
                try { p.resolve(JSON.parse(data)); } catch { p.resolve(data); }
            } else {
                p.resolve(data);
            }
        },
        handleError(requestId, message) {
            const p = pendingRequests.get(requestId);
            if (!p) return;
            pendingRequests.delete(requestId);
            p.reject(new Error(message));
        },
        updateMonacoTheme(editorBg, editorFg) {
            if (!monacoInstance || !editor) return;
            monacoInstance.editor.defineTheme('cmux-dark', {
                base: 'vs-dark', inherit: true, rules: [],
                colors: {
                    'editor.background': editorBg,
                    'editorGutter.background': editorBg,
                    'editor.lineHighlightBackground': editorBg + '22',
                    'editorLineNumber.foreground': editorFg + '55',
                    'editorLineNumber.activeForeground': editorFg + 'cc'
                }
            });
            monacoInstance.editor.setTheme('cmux-dark');
            document.documentElement.style.setProperty('--editor-bg', editorBg);
        },

        // Called from Swift to open a file
        async openFile(relativePath, fileName) {
            if (!editor || !monacoInstance) {
                // Queue for after init
                window.cmux._pendingOpen = { relativePath, fileName };
                return;
            }
            await doOpenFile(relativePath, fileName);
        },

        // Called from Swift with file content already read — no bridge round-trips
        openFileWithContent(relativePath, fileName, content) {
            if (!editor || !monacoInstance) {
                window.cmux._pendingOpen = { relativePath, fileName, content };
                return;
            }
            doOpenFileWithContent(relativePath, fileName, content);
        },

        // Called from Swift when file is too large
        showLargeFile(fileName, reason) {
            currentFilePath = null;
            if (editor) editor.setModel(null);
            showLargeFileNotice(fileName, reason);
            notifyActive(fileName);
        },

        // Called from Swift with Monaco paths — triggers init
        initMonaco(vsPath, cssHref) {
            // Inject CSS
            if (cssHref) {
                const link = document.createElement('link');
                link.rel = 'stylesheet';
                link.href = cssHref;
                document.head.appendChild(link);
            }
            // Load Monaco loader
            const script = document.createElement('script');
            script.onload = function() { bootstrapMonaco(vsPath); };
            script.src = vsPath + '/loader.js';
            document.head.appendChild(script);
        }
    };

    const MAX_FILE_SIZE = 1024 * 1024; // 1 MB
    const MAX_LINE_COUNT = 50000;

    function showLargeFileNotice(fileName, reason) {
        document.getElementById('editor-container').style.display = 'none';
        const notice = document.getElementById('large-file-notice');
        document.getElementById('large-file-name').textContent = fileName;
        document.getElementById('large-file-message').textContent = reason;
        notice.classList.add('visible');
    }

    function hideLargeFileNotice() {
        document.getElementById('large-file-notice').classList.remove('visible');
        document.getElementById('editor-container').style.display = '';
    }

    function doOpenFileWithContent(relativePath, fileName, content) {
        hideLargeFileNotice();
        currentFilePath = relativePath;
        originalContent = content;
        isDirty = false;
        const lang = getLang(fileName);
        const model = monacoInstance.editor.createModel(content, lang);
        const oldModel = editor.getModel();
        editor.setModel(model);
        if (oldModel) oldModel.dispose();
        model.onDidChangeContent(() => {
            const nowDirty = model.getValue() !== originalContent;
            if (nowDirty !== isDirty) {
                isDirty = nowDirty;
                notifyDirty(isDirty);
            }
        });
        notifyActive(fileName);
    }

    async function doOpenFile(relativePath, fileName) {
        try {
            // Check file size before reading content
            const stat = await statFile(relativePath);
            if (stat.size > MAX_FILE_SIZE) {
                const sizeMB = (stat.size / (1024 * 1024)).toFixed(1);
                currentFilePath = relativePath;
                if (editor) editor.setModel(null);
                showLargeFileNotice(fileName, `${sizeMB} MB — file is too large to open in the editor`);
                notifyActive(fileName);
                return;
            }

            const content = await readFile(relativePath);

            const lineCount = content.split('\n').length;
            if (lineCount > MAX_LINE_COUNT) {
                currentFilePath = relativePath;
                if (editor) editor.setModel(null);
                showLargeFileNotice(fileName, `${lineCount.toLocaleString()} lines — file is too large to open in the editor`);
                notifyActive(fileName);
                return;
            }

            hideLargeFileNotice();
            currentFilePath = relativePath;
            originalContent = content;
            isDirty = false;
            const lang = getLang(fileName);
            const model = monacoInstance.editor.createModel(content, lang);
            const oldModel = editor.getModel();
            editor.setModel(model);
            if (oldModel) oldModel.dispose();
            model.onDidChangeContent(() => {
                const nowDirty = model.getValue() !== originalContent;
                if (nowDirty !== isDirty) {
                    isDirty = nowDirty;
                    notifyDirty(isDirty);
                }
            });
            notifyActive(fileName);
        } catch (err) {
            console.error('Open failed:', err);
        }
    }

    function post(action, params = {}) {
        return new Promise((resolve, reject) => {
            const requestId = 'r' + (++requestCounter);
            pendingRequests.set(requestId, { resolve, reject });
            window.webkit.messageHandlers.cmuxEditor.postMessage({ action, requestId, ...params });
        });
    }

    const readFile = async (path) => (await post('readFile', { path })).content;
    const writeFile = (path, content) => post('writeFile', { path, content });
    const statFile = (path) => post('statFile', { path });

    function notifyDirty(d) {
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'dirtyState', isDirty: d });
    }
    function notifyActive(n) {
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'activeFile', fileName: n || null });
    }
    function notifyReady() {
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'editorReady' });
    }

    function getLang(name) {
        const ext = (name || '').split('.').pop().toLowerCase();
        const m = {
            js:'javascript',jsx:'javascript',mjs:'javascript',cjs:'javascript',
            ts:'typescript',tsx:'typescript',
            py:'python',rb:'ruby',rs:'rust',go:'go',java:'java',kt:'kotlin',
            c:'c',h:'c',cpp:'cpp',hpp:'cpp',cs:'csharp',swift:'swift',
            html:'html',htm:'html',css:'css',scss:'scss',less:'less',
            json:'json',yaml:'yaml',yml:'yaml',xml:'xml',svg:'xml',
            md:'markdown',sh:'shell',bash:'shell',zsh:'shell',fish:'shell',
            sql:'sql',toml:'ini',ini:'ini',dockerfile:'dockerfile',
            lua:'lua',php:'php',r:'r',zig:'zig'
        };
        return m[ext] || 'plaintext';
    }

    async function saveActive() {
        if (!currentFilePath || !editor) return;
        const content = editor.getModel().getValue();
        try {
            await writeFile(currentFilePath, content);
            originalContent = content;
            isDirty = false;
            notifyDirty(false);
        } catch (err) { console.error('Save failed:', err); }
    }

    function bootstrapMonaco(vsPath) {
        require.config({ paths: { vs: vsPath } });

        require(['vs/editor/editor.main'], async function (monaco) {
            monacoInstance = monaco;

            monaco.editor.defineTheme('cmux-dark', {
                base: 'vs-dark', inherit: true, rules: [],
                colors: {
                    'editor.background': '#1f1f1f',
                    'editorGutter.background': '#1f1f1f',
                    'editor.lineHighlightBackground': '#2a2d2e',
                    'editorLineNumber.foreground': '#5a5a5a',
                    'editorLineNumber.activeForeground': '#c6c6c6'
                }
            });

            editor = monaco.editor.create(document.getElementById('editor-container'), {
                theme: 'cmux-dark',
                fontSize: 13,
                fontFamily: "'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace",
                minimap: { enabled: false },
                scrollBeyondLastLine: false,
                automaticLayout: true,
                wordWrap: 'off',
                renderWhitespace: 'selection',
                lineNumbers: 'on',
                roundedSelection: false,
                cursorBlinking: 'smooth',
                smoothScrolling: true,
                padding: { top: 8, bottom: 8 },
                overviewRulerBorder: false,
                bracketPairColorization: { enabled: true },
                guides: { indentation: true, bracketPairs: true },
                stickyScroll: { enabled: true }
            });

            editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => saveActive());

            // Disable Monaco shortcuts that conflict with cmux
            // Cmd+Shift+F (find in files), Cmd+P (quick open), Cmd+Shift+P (command palette)
            editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyF, () => {});
            editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyP, () => {});
            editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyP, () => {});
            editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyN, () => {});
            editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyN, () => {});

            notifyReady();

            // Open any file that was queued before Monaco was ready
            if (window.cmux._pendingOpen) {
                const pending = window.cmux._pendingOpen;
                delete window.cmux._pendingOpen;
                if (pending.content !== undefined) {
                    doOpenFileWithContent(pending.relativePath, pending.fileName, pending.content);
                } else {
                    await doOpenFile(pending.relativePath, pending.fileName);
                }
            }
        });
    }
})();
