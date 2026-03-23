// cmux Editor — single-file Monaco editor
// Swift bridge via window.webkit.messageHandlers.cmuxEditor

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
                base: 'vs-dark',
                inherit: true,
                rules: [],
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
        // Called from Swift to open a file by relative path
        async openFile(relativePath, fileName) {
            if (!editor || !monacoInstance) return;
            try {
                const content = await readFile(relativePath);
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
                notifyReady();
            } catch (err) {
                console.error('Open failed:', err);
            }
        }
    };

    function post(action, params = {}) {
        return new Promise((resolve, reject) => {
            const requestId = 'r' + (++requestCounter);
            pendingRequests.set(requestId, { resolve, reject });
            window.webkit.messageHandlers.cmuxEditor.postMessage({ action, requestId, ...params });
        });
    }

    const readFile = async (path) => (await post('readFile', { path })).content;
    const writeFile = (path, content) => post('writeFile', { path, content });

    function notifyDirty(d) {
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'dirtyState', isDirty: d });
    }
    function notifyActive(n) {
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'activeFile', fileName: n || null });
    }
    function notifyReady() {
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'editorReady' });
    }

    // ── Language Detection ─────────────────────────────────────────────
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

    // ── Save ───────────────────────────────────────────────────────────
    async function saveActive() {
        if (!currentFilePath || !editor) return;
        const content = editor.getModel().getValue();
        try {
            await writeFile(currentFilePath, content);
            originalContent = content;
            isDirty = false;
            notifyDirty(false);
        } catch (err) {
            console.error('Save failed:', err);
        }
    }

    // ── Monaco Init ────────────────────────────────────────────────────
    require.config({ paths: { vs: 'https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs' } });

    require(['vs/editor/editor.main'], function (monaco) {
        monacoInstance = monaco;

        monaco.editor.defineTheme('cmux-dark', {
            base: 'vs-dark',
            inherit: true,
            rules: [],
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

        // Signal ready
        notifyReady();
    });
})();
