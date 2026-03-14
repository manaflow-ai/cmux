// cmux Editor — Monaco-based file editor panel
// Communicates with Swift via window.webkit.messageHandlers.cmuxEditor

(function () {
    'use strict';

    // ── State ──────────────────────────────────────────────────────────
    let editor = null;
    let monacoInstance = null;
    const openFiles = new Map(); // path -> { model, viewState, isDirty }
    let activeFilePath = null;
    let requestCounter = 0;
    const pendingRequests = new Map(); // requestId -> { resolve, reject }
    let watchInterval = null;
    let lastTreeSnapshot = '';

    // ── Swift Bridge ───────────────────────────────────────────────────
    window.cmux = {
        handleResponse(requestId, jsonString) {
            const pending = pendingRequests.get(requestId);
            if (!pending) return;
            pendingRequests.delete(requestId);
            try {
                pending.resolve(JSON.parse(jsonString));
            } catch {
                pending.resolve(jsonString);
            }
        },
        handleError(requestId, message) {
            const pending = pendingRequests.get(requestId);
            if (!pending) return;
            pendingRequests.delete(requestId);
            pending.reject(new Error(message));
        }
    };

    function postMessage(action, params = {}) {
        return new Promise((resolve, reject) => {
            const requestId = 'req_' + (++requestCounter);
            pendingRequests.set(requestId, { resolve, reject });
            window.webkit.messageHandlers.cmuxEditor.postMessage({
                action,
                requestId,
                ...params
            });
        });
    }

    // ── File Operations ────────────────────────────────────────────────
    async function readDir(path) {
        return postMessage('readDir', { path });
    }

    async function readFile(path) {
        const result = await postMessage('readFile', { path });
        return result.content;
    }

    async function writeFile(path, content) {
        return postMessage('writeFile', { path, content });
    }

    async function createFile(path) {
        return postMessage('createFile', { path });
    }

    async function createDir(path) {
        return postMessage('createDir', { path });
    }

    function notifyDirtyState() {
        let anyDirty = false;
        for (const file of openFiles.values()) {
            if (file.isDirty) { anyDirty = true; break; }
        }
        window.webkit.messageHandlers.cmuxEditor.postMessage({
            action: 'dirtyState',
            isDirty: anyDirty
        });
    }

    function notifyActiveFile(fileName) {
        window.webkit.messageHandlers.cmuxEditor.postMessage({
            action: 'activeFile',
            fileName: fileName || null
        });
    }

    // ── Language Detection ─────────────────────────────────────────────
    function getLanguage(filename) {
        const ext = filename.split('.').pop().toLowerCase();
        const map = {
            js: 'javascript', jsx: 'javascript',
            ts: 'typescript', tsx: 'typescript',
            py: 'python', rb: 'ruby',
            rs: 'rust', go: 'go',
            java: 'java', kt: 'kotlin',
            c: 'c', h: 'c', cpp: 'cpp', hpp: 'cpp',
            cs: 'csharp',
            swift: 'swift',
            html: 'html', htm: 'html',
            css: 'css', scss: 'scss', less: 'less',
            json: 'json', yaml: 'yaml', yml: 'yaml',
            xml: 'xml', svg: 'xml',
            md: 'markdown',
            sh: 'shell', bash: 'shell', zsh: 'shell',
            sql: 'sql',
            toml: 'ini', ini: 'ini',
            dockerfile: 'dockerfile',
            makefile: 'makefile',
            lua: 'lua', php: 'php', r: 'r',
            zig: 'zig'
        };
        return map[ext] || 'plaintext';
    }

    // ── File Icon ──────────────────────────────────────────────────────
    function getFileIconClass(name, isDirectory) {
        if (isDirectory) return 'folder';
        const ext = name.split('.').pop().toLowerCase();
        const map = {
            js: 'file-js', jsx: 'file-js', mjs: 'file-js', cjs: 'file-js',
            ts: 'file-ts', tsx: 'file-ts',
            json: 'file-json',
            html: 'file-html', htm: 'file-html',
            css: 'file-css', scss: 'file-css', less: 'file-css',
            md: 'file-md', markdown: 'file-md',
            py: 'file-py',
            rs: 'file-rs',
            go: 'file-go',
            swift: 'file-swift'
        };
        return map[ext] || 'file-default';
    }

    function getFileIconChar(name, isDirectory) {
        if (isDirectory) return '\u{1F4C1}';
        return '\u{1F4C4}';
    }

    // ── File Tree ──────────────────────────────────────────────────────
    const treeEl = document.getElementById('file-tree');
    const expandedDirs = new Set();

    async function renderTree(parentEl, path, depth) {
        try {
            const entries = await readDir(path);
            // Sort: directories first, then files, both alphabetical
            entries.sort((a, b) => {
                if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
                return a.name.localeCompare(b.name);
            });

            for (const entry of entries) {
                const fullPath = path ? path + '/' + entry.name : entry.name;
                const item = document.createElement('div');
                item.className = 'tree-item';
                item.dataset.path = fullPath;
                item.dataset.isDir = entry.isDirectory ? '1' : '0';
                if (fullPath === activeFilePath) item.classList.add('selected');

                const indent = document.createElement('span');
                indent.className = 'tree-item-indent';
                indent.style.width = (depth * 12 + 8) + 'px';
                item.appendChild(indent);

                const chevron = document.createElement('span');
                chevron.className = 'tree-item-chevron';
                if (entry.isDirectory) {
                    chevron.textContent = '\u25B6'; // right-pointing triangle
                    if (expandedDirs.has(fullPath)) chevron.classList.add('expanded');
                } else {
                    chevron.classList.add('file-spacer');
                }
                item.appendChild(chevron);

                const icon = document.createElement('span');
                icon.className = 'tree-item-icon ' + getFileIconClass(entry.name, entry.isDirectory);
                icon.textContent = getFileIconChar(entry.name, entry.isDirectory);
                item.appendChild(icon);

                const nameEl = document.createElement('span');
                nameEl.className = 'tree-item-name';
                nameEl.textContent = entry.name;
                item.appendChild(nameEl);

                parentEl.appendChild(item);

                if (entry.isDirectory) {
                    const childrenContainer = document.createElement('div');
                    childrenContainer.className = 'tree-children';
                    if (expandedDirs.has(fullPath)) {
                        childrenContainer.classList.add('expanded');
                        await renderTree(childrenContainer, fullPath, depth + 1);
                    }
                    parentEl.appendChild(childrenContainer);

                    item.addEventListener('click', async (e) => {
                        e.stopPropagation();
                        if (expandedDirs.has(fullPath)) {
                            expandedDirs.delete(fullPath);
                            chevron.classList.remove('expanded');
                            childrenContainer.classList.remove('expanded');
                            childrenContainer.innerHTML = '';
                        } else {
                            expandedDirs.add(fullPath);
                            chevron.classList.add('expanded');
                            childrenContainer.innerHTML = '';
                            await renderTree(childrenContainer, fullPath, depth + 1);
                            childrenContainer.classList.add('expanded');
                        }
                    });
                } else {
                    item.addEventListener('click', (e) => {
                        e.stopPropagation();
                        openFile(fullPath, entry.name);
                    });
                }

                // Right-click context menu
                item.addEventListener('contextmenu', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    showContextMenu(e.clientX, e.clientY, fullPath, entry.isDirectory);
                });
            }
        } catch (err) {
            console.error('readDir failed:', err);
        }
    }

    function updateTreeSelection() {
        treeEl.querySelectorAll('.tree-item').forEach(el => el.classList.remove('selected'));
    }

    // Full tree refresh preserving expanded state
    async function refreshTree() {
        treeEl.innerHTML = '';
        await renderTree(treeEl, '', 0);
    }

    // ── File Watching ──────────────────────────────────────────────────
    async function buildTreeSnapshot(path) {
        try {
            const entries = await readDir(path);
            let snapshot = '';
            entries.sort((a, b) => a.name.localeCompare(b.name));
            for (const entry of entries) {
                const fullPath = path ? path + '/' + entry.name : entry.name;
                snapshot += fullPath + (entry.isDirectory ? '/' : '') + '\n';
                if (entry.isDirectory && expandedDirs.has(fullPath)) {
                    snapshot += await buildTreeSnapshot(fullPath);
                }
            }
            return snapshot;
        } catch {
            return '';
        }
    }

    async function checkForChanges() {
        const snapshot = await buildTreeSnapshot('');
        if (snapshot !== lastTreeSnapshot) {
            lastTreeSnapshot = snapshot;
            await refreshTree();
        }
    }

    function startWatching() {
        if (watchInterval) clearInterval(watchInterval);
        watchInterval = setInterval(checkForChanges, 2000);
    }

    // ── Context Menu ───────────────────────────────────────────────────
    let activeContextMenu = null;

    function removeContextMenu() {
        if (activeContextMenu) {
            activeContextMenu.remove();
            activeContextMenu = null;
        }
    }

    document.addEventListener('click', removeContextMenu);
    document.addEventListener('contextmenu', (e) => {
        // Remove old menu on any right-click
        removeContextMenu();
    });

    function showContextMenu(x, y, targetPath, isDirectory) {
        removeContextMenu();

        const menu = document.createElement('div');
        menu.className = 'context-menu';
        menu.style.left = x + 'px';
        menu.style.top = y + 'px';

        const parentDir = isDirectory ? targetPath : targetPath.substring(0, targetPath.lastIndexOf('/')) || '';

        const newFileItem = document.createElement('div');
        newFileItem.className = 'context-menu-item';
        newFileItem.textContent = 'New File';
        newFileItem.addEventListener('click', (e) => {
            e.stopPropagation();
            removeContextMenu();
            promptNewFile(parentDir);
        });
        menu.appendChild(newFileItem);

        const newFolderItem = document.createElement('div');
        newFolderItem.className = 'context-menu-item';
        newFolderItem.textContent = 'New Folder';
        newFolderItem.addEventListener('click', (e) => {
            e.stopPropagation();
            removeContextMenu();
            promptNewFolder(parentDir);
        });
        menu.appendChild(newFolderItem);

        document.body.appendChild(menu);
        activeContextMenu = menu;

        // Keep menu in viewport
        const rect = menu.getBoundingClientRect();
        if (rect.right > window.innerWidth) menu.style.left = (window.innerWidth - rect.width - 4) + 'px';
        if (rect.bottom > window.innerHeight) menu.style.top = (window.innerHeight - rect.height - 4) + 'px';
    }

    // ── Inline Input for New File/Folder ───────────────────────────────
    function promptNewFile(parentDir) {
        showInlineInput(parentDir, async (name) => {
            const path = parentDir ? parentDir + '/' + name : name;
            try {
                await createFile(path);
                // Ensure parent dir is expanded
                if (parentDir) expandedDirs.add(parentDir);
                await refreshTree();
                lastTreeSnapshot = await buildTreeSnapshot('');
                openFile(path, name);
            } catch (err) {
                console.error('Failed to create file:', err);
            }
        });
    }

    function promptNewFolder(parentDir) {
        showInlineInput(parentDir, async (name) => {
            const path = parentDir ? parentDir + '/' + name : name;
            try {
                await createDir(path);
                if (parentDir) expandedDirs.add(parentDir);
                expandedDirs.add(path);
                await refreshTree();
                lastTreeSnapshot = await buildTreeSnapshot('');
            } catch (err) {
                console.error('Failed to create folder:', err);
            }
        });
    }

    function showInlineInput(parentDir, onConfirm) {
        // Find the tree-children container for the parent dir, or use the root
        let container = treeEl;
        if (parentDir) {
            // Find the dir item and its children container
            const items = treeEl.querySelectorAll('.tree-item');
            for (const item of items) {
                if (item.dataset.path === parentDir && item.dataset.isDir === '1') {
                    const nextEl = item.nextElementSibling;
                    if (nextEl && nextEl.classList.contains('tree-children')) {
                        container = nextEl;
                        // Ensure expanded
                        if (!container.classList.contains('expanded')) {
                            expandedDirs.add(parentDir);
                            container.classList.add('expanded');
                        }
                    }
                    break;
                }
            }
        }

        const inputRow = document.createElement('div');
        inputRow.className = 'tree-item tree-input-row';

        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'tree-inline-input';
        input.placeholder = 'name...';
        inputRow.appendChild(input);

        container.insertBefore(inputRow, container.firstChild);
        input.focus();

        function commit() {
            const name = input.value.trim();
            inputRow.remove();
            if (name && !name.includes('/') && !name.includes('..')) {
                onConfirm(name);
            }
        }

        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                commit();
            } else if (e.key === 'Escape') {
                e.preventDefault();
                inputRow.remove();
            }
        });

        input.addEventListener('blur', () => {
            // Small delay to allow click events to fire
            setTimeout(() => {
                if (inputRow.parentNode) commit();
            }, 100);
        });
    }

    // ── Sidebar Header Buttons ─────────────────────────────────────────
    function setupHeaderButtons() {
        const header = document.getElementById('sidebar-header');

        const btnGroup = document.createElement('span');
        btnGroup.className = 'header-buttons';

        const newFileBtn = document.createElement('button');
        newFileBtn.className = 'header-btn';
        newFileBtn.title = 'New File';
        newFileBtn.textContent = '\u{1F4C4}';
        newFileBtn.addEventListener('click', () => promptNewFile(''));
        btnGroup.appendChild(newFileBtn);

        const newFolderBtn = document.createElement('button');
        newFolderBtn.className = 'header-btn';
        newFolderBtn.title = 'New Folder';
        newFolderBtn.textContent = '\u{1F4C1}';
        newFolderBtn.addEventListener('click', () => promptNewFolder(''));
        btnGroup.appendChild(newFolderBtn);

        const refreshBtn = document.createElement('button');
        refreshBtn.className = 'header-btn';
        refreshBtn.title = 'Refresh';
        refreshBtn.textContent = '\u21BB';
        refreshBtn.addEventListener('click', async () => {
            await refreshTree();
            lastTreeSnapshot = await buildTreeSnapshot('');
        });
        btnGroup.appendChild(refreshBtn);

        header.appendChild(btnGroup);
    }

    // ── Tabs ───────────────────────────────────────────────────────────
    const tabsBar = document.getElementById('tabs-bar');

    function renderTabs() {
        tabsBar.innerHTML = '';
        for (const [path, file] of openFiles) {
            const tab = document.createElement('div');
            tab.className = 'tab';
            if (path === activeFilePath) tab.classList.add('active');
            if (file.isDirty) tab.classList.add('dirty');

            const name = document.createElement('span');
            name.className = 'tab-name';
            name.textContent = path.split('/').pop();
            tab.appendChild(name);

            const dirty = document.createElement('span');
            dirty.className = 'tab-dirty';
            tab.appendChild(dirty);

            const close = document.createElement('span');
            close.className = 'tab-close';
            close.textContent = '\u00D7';
            close.addEventListener('click', (e) => {
                e.stopPropagation();
                closeFile(path);
            });
            tab.appendChild(close);

            tab.addEventListener('click', () => switchToFile(path));
            tabsBar.appendChild(tab);
        }
    }

    // ── File Management ────────────────────────────────────────────────
    async function openFile(path, name) {
        if (openFiles.has(path)) {
            switchToFile(path);
            return;
        }

        try {
            const content = await readFile(path);
            const language = getLanguage(name);
            const model = monacoInstance.editor.createModel(content, language);

            model.onDidChangeContent(() => {
                const file = openFiles.get(path);
                if (!file) return;
                const wasDirty = file.isDirty;
                file.isDirty = model.getValue() !== file.originalContent;
                if (wasDirty !== file.isDirty) {
                    renderTabs();
                    notifyDirtyState();
                }
            });

            openFiles.set(path, {
                model,
                viewState: null,
                isDirty: false,
                originalContent: content
            });

            switchToFile(path);
        } catch (err) {
            console.error('Failed to open file:', err);
        }
    }

    function switchToFile(path) {
        if (!openFiles.has(path)) return;

        // Save current view state
        if (activeFilePath && openFiles.has(activeFilePath)) {
            openFiles.get(activeFilePath).viewState = editor.saveViewState();
        }

        activeFilePath = path;
        const file = openFiles.get(path);

        editor.setModel(file.model);
        if (file.viewState) {
            editor.restoreViewState(file.viewState);
        }
        editor.focus();

        document.getElementById('editor-container').classList.add('visible');
        document.getElementById('welcome').classList.remove('welcome-visible');

        renderTabs();
        updateTreeSelection();
        notifyActiveFile(path.split('/').pop());
    }

    function closeFile(path) {
        const file = openFiles.get(path);
        if (!file) return;

        file.model.dispose();
        openFiles.delete(path);

        if (activeFilePath === path) {
            const remaining = Array.from(openFiles.keys());
            if (remaining.length > 0) {
                switchToFile(remaining[remaining.length - 1]);
            } else {
                activeFilePath = null;
                editor.setModel(null);
                document.getElementById('editor-container').classList.remove('visible');
                document.getElementById('welcome').classList.add('welcome-visible');
                notifyActiveFile(null);
            }
        }

        renderTabs();
        notifyDirtyState();
    }

    async function saveActiveFile() {
        if (!activeFilePath) return;
        const file = openFiles.get(activeFilePath);
        if (!file || !file.isDirty) return;

        try {
            const content = file.model.getValue();
            await writeFile(activeFilePath, content);
            file.originalContent = content;
            file.isDirty = false;
            renderTabs();
            notifyDirtyState();
        } catch (err) {
            console.error('Failed to save file:', err);
        }
    }

    // ── Sidebar Resize ─────────────────────────────────────────────────
    const sidebar = document.getElementById('sidebar');
    const resizeHandle = document.getElementById('sidebar-resize-handle');
    let isResizing = false;

    resizeHandle.addEventListener('mousedown', (e) => {
        isResizing = true;
        document.body.style.cursor = 'col-resize';
        e.preventDefault();
    });

    document.addEventListener('mousemove', (e) => {
        if (!isResizing) return;
        const newWidth = Math.max(140, Math.min(400, e.clientX));
        sidebar.style.width = newWidth + 'px';
    });

    document.addEventListener('mouseup', () => {
        if (isResizing) {
            isResizing = false;
            document.body.style.cursor = '';
            if (editor) editor.layout();
        }
    });

    // ── Keyboard Shortcuts ─────────────────────────────────────────────
    document.addEventListener('keydown', (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === 's') {
            e.preventDefault();
            saveActiveFile();
        }
        if ((e.metaKey || e.ctrlKey) && e.key === 'w') {
            e.preventDefault();
            if (activeFilePath) closeFile(activeFilePath);
        }
        if ((e.metaKey || e.ctrlKey) && e.key === 'n') {
            e.preventDefault();
            // New file in root
            promptNewFile('');
        }
    });

    // ── Monaco Initialization ──────────────────────────────────────────
    require.config({
        paths: { vs: 'https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs' }
    });

    require(['vs/editor/editor.main'], function (monaco) {
        monacoInstance = monaco;

        // Define cmux dark theme
        monaco.editor.defineTheme('cmux-dark', {
            base: 'vs-dark',
            inherit: true,
            rules: [],
            colors: {
                'editor.background': '#1e1e1e',
                'editorGutter.background': '#1e1e1e',
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
            overviewRulerBorder: false
        });

        // Handle Cmd+S within Monaco
        editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
            saveActiveFile();
        });

        // Load the file tree
        renderTree(treeEl, '', 0).then(async () => {
            lastTreeSnapshot = await buildTreeSnapshot('');
            startWatching();
        });

        // Set up header buttons
        setupHeaderButtons();

        const projectNameEl = document.getElementById('project-name');
        projectNameEl.textContent = 'EXPLORER';
    });
})();
