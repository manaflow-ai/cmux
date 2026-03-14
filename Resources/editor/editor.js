// cmux Editor — VS Code-faithful explorer + Monaco editor
// Swift bridge via window.webkit.messageHandlers.cmuxEditor

(function () {
    'use strict';

    // ── State ──────────────────────────────────────────────────────────
    let editor = null;
    let monacoInstance = null;
    const openFiles = new Map(); // path -> { model, viewState, isDirty, originalContent }
    let activeFilePath = null;
    let requestCounter = 0;
    const pendingRequests = new Map();
    let lastTreeSnapshot = '';
    let gitStatusMap = new Map(); // path -> status string
    let gitIgnoredSet = new Set(); // paths of ignored files
    let selectedTreePaths = new Set(); // multi-select
    let lastClickedPath = null; // for shift-click range select
    let selectedTreePath = null; // kept for compat (last focused item)
    let inlineInputActive = false; // pause watcher during rename/new file
    let dragSourcePath = null;
    let dragMouseStart = null; // { x, y, path, row }
    let isDragging = false;

    // ── Swift Bridge ───────────────────────────────────────────────────
    window.cmux = {
        handleResponse(requestId, data) {
            const p = pendingRequests.get(requestId);
            if (!p) return;
            pendingRequests.delete(requestId);
            // data may be a pre-parsed object (from JSON.parse in evaluateJavaScript) or a string
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
        // Called from Swift when theme changes
        updateMonacoTheme(editorBg, editorFg) {
            if (!monacoInstance || !editor) return;
            monacoInstance.editor.defineTheme('cmux-dark', {
                base: 'vs-dark',
                inherit: true,
                rules: [],
                colors: {
                    'editor.background': editorBg,
                    'editorGutter.background': editorBg,
                    'editor.lineHighlightBackground': editorBg + '20',
                    'editorLineNumber.foreground': editorFg + '55',
                    'editorLineNumber.activeForeground': editorFg + 'cc'
                }
            });
            monacoInstance.editor.setTheme('cmux-dark');
        }
    };

    function post(action, params = {}) {
        return new Promise((resolve, reject) => {
            const requestId = 'r' + (++requestCounter);
            pendingRequests.set(requestId, { resolve, reject });
            window.webkit.messageHandlers.cmuxEditor.postMessage({ action, requestId, ...params });
        });
    }

    // ── File Ops ───────────────────────────────────────────────────────
    const readDir = (path) => post('readDir', { path });
    const readFile = async (path) => (await post('readFile', { path })).content;
    const writeFile = (path, content) => post('writeFile', { path, content });
    const createFile = (path) => post('createFile', { path });
    const createDir = (path) => post('createDir', { path });
    const deleteFile = (path) => post('deleteFile', { path });
    const renameFile = (oldPath, newPath) => post('renameFile', { oldPath, newPath });
    const getGitStatus = () => post('gitStatus', {});

    function notifyDirty() {
        let d = false;
        for (const f of openFiles.values()) if (f.isDirty) { d = true; break; }
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'dirtyState', isDirty: d });
    }
    function notifyActive(n) {
        window.webkit.messageHandlers.cmuxEditor.postMessage({ action: 'activeFile', fileName: n || null });
    }

    // ── Language Detection ─────────────────────────────────────────────
    function getLang(name) {
        const ext = name.split('.').pop().toLowerCase();
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

    // ── File Icons (codicon classes) ───────────────────────────────────
    function fileIconClass(name, isDir, isOpen) {
        if (isDir) return isOpen ? 'icon-folder-open' : 'icon-folder';
        const ext = name.split('.').pop().toLowerCase();
        const m = {
            js:'icon-js',jsx:'icon-js',mjs:'icon-js',cjs:'icon-js',ts:'icon-ts',tsx:'icon-ts',
            json:'icon-json',html:'icon-html',htm:'icon-html',css:'icon-css',scss:'icon-css',
            md:'icon-md',py:'icon-py',rs:'icon-rs',go:'icon-go',swift:'icon-swift',
            rb:'icon-rb',java:'icon-java',c:'icon-c',cpp:'icon-cpp',h:'icon-c',hpp:'icon-cpp',
            sh:'icon-sh',bash:'icon-sh',zsh:'icon-sh',yml:'icon-yml',yaml:'icon-yml',
            toml:'icon-toml',zig:'icon-zig',
            png:'icon-image',jpg:'icon-image',jpeg:'icon-image',gif:'icon-image',svg:'icon-image',
            lock:'icon-lock'
        };
        return m[ext] || 'icon-file';
    }

    function fileCodiconChar(name, isDir, isOpen) {
        if (isDir) return isOpen ? '\uEAF7' : '\uEAF6'; // codicon folder-opened / folder
        return '\uEB60'; // codicon file
    }

    // ── Git Status ─────────────────────────────────────────────────────
    async function refreshGitStatus() {
        try {
            const result = await getGitStatus();
            gitStatusMap.clear();
            gitIgnoredSet.clear();
            for (const f of (result.files || [])) {
                gitStatusMap.set(f.path, f.status);
            }
            for (const f of (result.ignored || [])) {
                gitIgnoredSet.add(f.path);
            }
        } catch { /* git not available */ }
    }

    function getGitStatusForPath(path) {
        if (gitStatusMap.has(path)) return gitStatusMap.get(path);
        if (gitIgnoredSet.has(path)) return 'ignored';
        return null;
    }

    // Bubble git status to parent folders — returns the "worst" child status
    function getFolderGitStatus(folderPath) {
        const prefix = folderPath ? folderPath + '/' : '';
        let dominated = null;
        const priority = { conflict: 6, deleted: 5, modified: 4, renamed: 3, added: 2, untracked: 1 };
        for (const [path, status] of gitStatusMap) {
            if (path.startsWith(prefix)) {
                const p = priority[status] || 0;
                if (!dominated || p > (priority[dominated] || 0)) dominated = status;
            }
        }
        return dominated;
    }

    function gitBadgeLetter(status) {
        const m = { modified:'M', added:'A', deleted:'D', untracked:'U', renamed:'R', conflict:'!', ignored:'I' };
        return m[status] || '';
    }

    function gitLabelClass(status) {
        return status ? 'git-' + status : '';
    }

    function gitBadgeClass(status) {
        const m = { modified:'badge-M', added:'badge-A', deleted:'badge-D', untracked:'badge-U', renamed:'badge-R', conflict:'badge-C', ignored:'badge-I' };
        return m[status] || '';
    }

    // ── File Tree ──────────────────────────────────────────────────────
    const treeEl = document.getElementById('file-tree');
    const expandedDirs = new Set();

    async function renderTree(parentEl, path, depth) {
        let entries;
        try { entries = await readDir(path); } catch { return; }
        entries.sort((a, b) => {
            if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
            return a.name.localeCompare(b.name);
        });

        for (const entry of entries) {
            const fullPath = path ? path + '/' + entry.name : entry.name;
            const isExpanded = expandedDirs.has(fullPath);
            const gitStatus = entry.isDirectory ? getFolderGitStatus(fullPath) : getGitStatusForPath(fullPath);

            // Row
            const row = document.createElement('div');
            row.className = 'tree-row';
            row.dataset.path = fullPath;
            row.dataset.isDir = entry.isDirectory ? '1' : '0';
            if (fullPath === selectedTreePath) row.classList.add('selected');

            // Indent guides
            const indent = document.createElement('span');
            indent.className = 'tree-indent';
            for (let i = 0; i < depth; i++) {
                const guide = document.createElement('span');
                guide.className = 'indent-guide active';
                indent.appendChild(guide);
            }
            row.appendChild(indent);

            // Twistie
            const twistie = document.createElement('span');
            twistie.className = 'tree-twistie';
            if (entry.isDirectory) {
                twistie.textContent = '\uEAB6'; // codicon chevron-right
                if (isExpanded) twistie.classList.add('expanded');
            } else {
                twistie.classList.add('hidden');
            }
            row.appendChild(twistie);

            // Icon
            const icon = document.createElement('span');
            const iconCls = fileIconClass(entry.name, entry.isDirectory, isExpanded);
            icon.className = 'tree-icon ' + iconCls;
            icon.textContent = fileCodiconChar(entry.name, entry.isDirectory, isExpanded);
            row.appendChild(icon);

            // Label
            const label = document.createElement('span');
            label.className = 'tree-label';
            if (gitStatus) label.classList.add(gitLabelClass(gitStatus));
            label.textContent = entry.name;
            row.appendChild(label);

            // Git badge
            if (gitStatus && gitStatus !== 'ignored') {
                if (entry.isDirectory) {
                    // Dot indicator for folders with changed children
                    const dot = document.createElement('span');
                    dot.className = 'tree-badge badge-dot';
                    const colorVar = gitStatus === 'modified' ? '--git-modified' :
                                     gitStatus === 'added' ? '--git-added' :
                                     gitStatus === 'untracked' ? '--git-untracked' :
                                     gitStatus === 'deleted' ? '--git-deleted' :
                                     gitStatus === 'conflict' ? '--git-conflict' : '--git-modified';
                    dot.style.background = `var(${colorVar})`;
                    row.appendChild(dot);
                } else {
                    const badge = document.createElement('span');
                    badge.className = 'tree-badge ' + gitBadgeClass(gitStatus);
                    badge.textContent = gitBadgeLetter(gitStatus);
                    row.appendChild(badge);
                }
            }

            parentEl.appendChild(row);

            // Children container for directories
            if (entry.isDirectory) {
                const children = document.createElement('div');
                children.className = 'tree-children';
                if (isExpanded) {
                    children.classList.add('expanded');
                    await renderTree(children, fullPath, depth + 1);
                }
                parentEl.appendChild(children);

                row.addEventListener('click', async (e) => {
                    e.stopPropagation();
                    handleSelection(fullPath, e);
                    if (expandedDirs.has(fullPath)) {
                        expandedDirs.delete(fullPath);
                        twistie.classList.remove('expanded');
                        children.classList.remove('expanded');
                        children.innerHTML = '';
                        icon.className = 'tree-icon ' + fileIconClass(entry.name, true, false);
                        icon.textContent = fileCodiconChar(entry.name, true, false);
                    } else {
                        expandedDirs.add(fullPath);
                        twistie.classList.add('expanded');
                        children.innerHTML = '';
                        await renderTree(children, fullPath, depth + 1);
                        children.classList.add('expanded');
                        icon.className = 'tree-icon ' + fileIconClass(entry.name, true, true);
                        icon.textContent = fileCodiconChar(entry.name, true, true);
                    }
                });
            } else {
                row.addEventListener('click', (e) => {
                    e.stopPropagation();
                    handleSelection(fullPath, e);
                    // Only open file on plain click (not multi-select)
                    if (!e.shiftKey && !e.metaKey && !e.ctrlKey) {
                        openFile(fullPath, entry.name);
                    }
                });
            }

            // Custom mouse-based drag (WKWebView doesn't relay HTML5 drag events reliably)
            row.addEventListener('mousedown', (e) => {
                if (e.button !== 0) return;
                // If clicking an unselected item without modifier, it becomes the drag source alone
                // If clicking a selected item, drag all selected
                const paths = selectedTreePaths.has(fullPath) ? new Set(selectedTreePaths) : new Set([fullPath]);
                dragMouseStart = { x: e.clientX, y: e.clientY, paths, row };
            });

            // Right-click context menu
            row.addEventListener('contextmenu', (e) => {
                e.preventDefault();
                e.stopPropagation();
                // If right-clicking on an unselected item, select only it
                if (!selectedTreePaths.has(fullPath)) selectSingle(fullPath);
                showContextMenu(e.clientX, e.clientY, fullPath, entry.isDirectory, entry.name);
            });

            // Double-click to rename
            let clickTimer = null;
            row.addEventListener('dblclick', (e) => {
                e.preventDefault();
                e.stopPropagation();
                if (entry.isDirectory) return;
                startInlineRename(row, fullPath, entry.name);
            });
        }
    }

    function highlightSelected() {
        treeEl.querySelectorAll('.tree-row').forEach(r => {
            r.classList.toggle('selected', selectedTreePaths.has(r.dataset.path));
            r.classList.toggle('focused', r.dataset.path === selectedTreePath);
        });
    }

    // Get all visible row paths in DOM order
    function getVisiblePaths() {
        return Array.from(treeEl.querySelectorAll('.tree-row')).map(r => r.dataset.path);
    }

    function selectSingle(path) {
        selectedTreePaths.clear();
        selectedTreePaths.add(path);
        selectedTreePath = path;
        lastClickedPath = path;
        highlightSelected();
    }

    function selectToggle(path) {
        if (selectedTreePaths.has(path)) {
            selectedTreePaths.delete(path);
        } else {
            selectedTreePaths.add(path);
        }
        selectedTreePath = path;
        lastClickedPath = path;
        highlightSelected();
    }

    function selectRange(toPath) {
        const paths = getVisiblePaths();
        const fromIdx = paths.indexOf(lastClickedPath);
        const toIdx = paths.indexOf(toPath);
        if (fromIdx === -1 || toIdx === -1) { selectSingle(toPath); return; }
        const start = Math.min(fromIdx, toIdx);
        const end = Math.max(fromIdx, toIdx);
        // Don't clear existing Cmd selections, just add the range
        for (let i = start; i <= end; i++) {
            selectedTreePaths.add(paths[i]);
        }
        selectedTreePath = toPath;
        highlightSelected();
    }

    function handleSelection(path, e) {
        if (e.shiftKey && lastClickedPath) {
            selectRange(path);
        } else if (e.metaKey || e.ctrlKey) {
            selectToggle(path);
        } else {
            selectSingle(path);
        }
    }

    async function refreshTree() {
        treeEl.innerHTML = '';
        await renderTree(treeEl, '', 0);
    }

    // ── File Watching ──────────────────────────────────────────────────
    async function buildSnapshot(path) {
        try {
            const entries = await readDir(path);
            let s = '';
            entries.sort((a, b) => a.name.localeCompare(b.name));
            for (const e of entries) {
                const fp = path ? path + '/' + e.name : e.name;
                s += fp + (e.isDirectory ? '/' : '') + '\n';
                if (e.isDirectory && expandedDirs.has(fp)) s += await buildSnapshot(fp);
            }
            return s;
        } catch { return ''; }
    }

    let lastGitSnapshot = '';
    let pollRunning = false;

    async function poll() {
        if (inlineInputActive) return;
        if (dragSourcePath) return;
        if (pollRunning) return; // prevent overlapping async polls
        pollRunning = true;
        try {
        const snap = await buildSnapshot('');
        const oldGitSnap = lastGitSnapshot;
        await refreshGitStatus();
        // Build a simple git snapshot string to compare
        const gitSnap = Array.from(gitStatusMap.entries()).sort().map(e => e[0] + ':' + e[1]).join('\n')
            + '\n---\n' + Array.from(gitIgnoredSet).sort().join('\n');
        lastGitSnapshot = gitSnap;

        if (snap !== lastTreeSnapshot || gitSnap !== oldGitSnap) {
            lastTreeSnapshot = snap;
            await refreshTree();
        }
        } finally { pollRunning = false; }
    }

    function startWatching() {
        setInterval(poll, 2000);
    }

    // ── Context Menu ───────────────────────────────────────────────────
    let ctxMenu = null;
    function removeCtxMenu() { if (ctxMenu) { ctxMenu.remove(); ctxMenu = null; } }
    document.addEventListener('click', removeCtxMenu);

    function showContextMenu(x, y, targetPath, isDir, name) {
        removeCtxMenu();
        const menu = document.createElement('div');
        menu.className = 'context-menu';
        menu.style.left = x + 'px';
        menu.style.top = y + 'px';

        const parentDir = isDir ? targetPath : targetPath.substring(0, targetPath.lastIndexOf('/')) || '';

        const items = [
            { label: 'New File...', action: () => promptNewFile(parentDir) },
            { label: 'New Folder...', action: () => promptNewFolder(parentDir) },
            { separator: true },
            { label: 'Rename', shortcut: 'F2', action: () => {
                const row = treeEl.querySelector(`[data-path="${CSS.escape(targetPath)}"]`);
                if (row) startInlineRename(row, targetPath, name);
            }},
            { label: 'Delete', action: () => confirmDelete(targetPath, name, isDir) },
            { separator: true },
            { label: 'Copy Path', shortcut: '\u2318\u2325C', action: () => copyToClipboard(targetPath) },
            { label: 'Copy Relative Path', action: () => copyToClipboard(targetPath) },
        ];

        for (const item of items) {
            if (item.separator) {
                const sep = document.createElement('div');
                sep.className = 'context-menu-separator';
                menu.appendChild(sep);
                continue;
            }
            const el = document.createElement('div');
            el.className = 'context-menu-item';
            el.textContent = item.label;
            if (item.shortcut) {
                const sc = document.createElement('span');
                sc.className = 'shortcut';
                sc.textContent = item.shortcut;
                el.appendChild(sc);
            }
            el.addEventListener('click', (e) => { e.stopPropagation(); removeCtxMenu(); item.action(); });
            menu.appendChild(el);
        }

        document.body.appendChild(menu);
        ctxMenu = menu;

        // Keep in viewport
        const r = menu.getBoundingClientRect();
        if (r.right > window.innerWidth) menu.style.left = (window.innerWidth - r.width - 4) + 'px';
        if (r.bottom > window.innerHeight) menu.style.top = (window.innerHeight - r.height - 4) + 'px';
    }

    function copyToClipboard(text) {
        navigator.clipboard.writeText(text).catch(() => {});
    }

    async function confirmDelete(path, name, isDir) {
        // Simple confirm — could be a modal later
        if (!confirm(`Delete "${name}"?`)) return;
        try {
            await deleteFile(path);
            // Close if open in editor
            if (openFiles.has(path)) closeFileTab(path);
            await refreshTree();
            lastTreeSnapshot = await buildSnapshot('');
        } catch (err) { console.error('Delete failed:', err); }
    }

    // ── Inline Rename ──────────────────────────────────────────────────
    // F2 cycles: stem → full name → extension (VS Code behavior)
    function startInlineRename(row, path, name) {
        const label = row.querySelector('.tree-label');
        if (!label) return;
        inlineInputActive = true;

        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'tree-inline-input';
        input.value = name;

        // Select filename without extension
        const dotIdx = name.lastIndexOf('.');
        label.style.display = 'none';
        row.appendChild(input);
        input.focus();
        if (dotIdx > 0) {
            input.setSelectionRange(0, dotIdx);
        } else {
            input.select();
        }

        let selectionCycle = 0; // 0=stem, 1=full, 2=ext

        function commit() {
            inlineInputActive = false;
            const newName = input.value.trim();
            input.remove();
            label.style.display = '';
            if (newName && newName !== name && !newName.includes('/')) {
                const parentDir = path.substring(0, path.lastIndexOf('/'));
                const newPath = parentDir ? parentDir + '/' + newName : newName;
                renameFile(path, newPath).then(async () => {
                    // Update open file if renamed
                    if (openFiles.has(path)) {
                        const file = openFiles.get(path);
                        openFiles.delete(path);
                        openFiles.set(newPath, file);
                        if (activeFilePath === path) activeFilePath = newPath;
                        renderTabs();
                    }
                    await refreshTree();
                    lastTreeSnapshot = await buildSnapshot('');
                }).catch(err => console.error('Rename failed:', err));
            }
        }

        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); commit(); }
            else if (e.key === 'Escape') { e.preventDefault(); inlineInputActive = false; input.remove(); label.style.display = ''; }
            else if (e.key === 'F2') {
                e.preventDefault();
                selectionCycle = (selectionCycle + 1) % 3;
                const dot = name.lastIndexOf('.');
                if (selectionCycle === 0 && dot > 0) input.setSelectionRange(0, dot);
                else if (selectionCycle === 1) input.select();
                else if (selectionCycle === 2 && dot > 0) input.setSelectionRange(dot + 1, name.length);
                else input.select();
            }
        });

        input.addEventListener('blur', () => {
            setTimeout(() => { if (input.parentNode) commit(); }, 100);
        });
    }

    // ── New File / Folder ──────────────────────────────────────────────
    function promptNewFile(parentDir) {
        showInlineInput(parentDir, async (name) => {
            const path = parentDir ? parentDir + '/' + name : name;
            try {
                await createFile(path);
                if (parentDir) expandedDirs.add(parentDir);
                await refreshTree();
                lastTreeSnapshot = await buildSnapshot('');
                openFile(path, name);
            } catch (err) { console.error('Create file failed:', err); }
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
                lastTreeSnapshot = await buildSnapshot('');
            } catch (err) { console.error('Create folder failed:', err); }
        });
    }

    function showInlineInput(parentDir, onConfirm) {
        let container = treeEl;
        if (parentDir) {
            const rows = treeEl.querySelectorAll('.tree-row');
            for (const row of rows) {
                if (row.dataset.path === parentDir && row.dataset.isDir === '1') {
                    const next = row.nextElementSibling;
                    if (next && next.classList.contains('tree-children')) {
                        container = next;
                        if (!container.classList.contains('expanded')) {
                            expandedDirs.add(parentDir);
                            container.classList.add('expanded');
                        }
                    }
                    break;
                }
            }
        }

        inlineInputActive = true;
        const inputRow = document.createElement('div');
        inputRow.className = 'tree-row tree-input-row';
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'tree-inline-input';
        input.placeholder = 'name...';
        inputRow.appendChild(input);
        container.insertBefore(inputRow, container.firstChild);
        input.focus();

        function commit() {
            inlineInputActive = false;
            const name = input.value.trim();
            inputRow.remove();
            if (name && !name.includes('/') && !name.includes('..')) onConfirm(name);
        }

        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); commit(); }
            else if (e.key === 'Escape') { e.preventDefault(); inlineInputActive = false; inputRow.remove(); }
        });
        input.addEventListener('blur', () => { setTimeout(() => { if (inputRow.parentNode) commit(); }, 100); });
    }

    // ── Sidebar Header ─────────────────────────────────────────────────
    function setupHeader() {
        const header = document.getElementById('sidebar-header');
        const btns = document.createElement('span');
        btns.className = 'header-buttons';

        // New File
        const b1 = document.createElement('button');
        b1.className = 'header-btn';
        b1.title = 'New File';
        b1.textContent = '\uEB60'; // codicon: file-add → using file
        b1.addEventListener('click', () => promptNewFile(selectedTreePath && treeEl.querySelector(`[data-path="${CSS.escape(selectedTreePath)}"][data-is-dir="1"]`) ? selectedTreePath : ''));
        btns.appendChild(b1);

        // New Folder
        const b2 = document.createElement('button');
        b2.className = 'header-btn';
        b2.title = 'New Folder';
        b2.textContent = '\uEAF6'; // codicon: folder
        b2.addEventListener('click', () => promptNewFolder(selectedTreePath && treeEl.querySelector(`[data-path="${CSS.escape(selectedTreePath)}"][data-is-dir="1"]`) ? selectedTreePath : ''));
        btns.appendChild(b2);

        // Refresh
        const b3 = document.createElement('button');
        b3.className = 'header-btn';
        b3.title = 'Refresh Explorer';
        b3.textContent = '\uEB37'; // codicon: refresh
        b3.addEventListener('click', async () => {
            await refreshGitStatus();
            await refreshTree();
            lastTreeSnapshot = await buildSnapshot('');
        });
        btns.appendChild(b3);

        // Collapse All
        const b4 = document.createElement('button');
        b4.className = 'header-btn';
        b4.title = 'Collapse All';
        b4.textContent = '\uEAC5'; // codicon: collapse-all
        b4.addEventListener('click', () => {
            expandedDirs.clear();
            refreshTree();
        });
        btns.appendChild(b4);

        header.appendChild(btns);
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
            close.textContent = '\uEAB8'; // codicon: close
            close.addEventListener('click', (e) => { e.stopPropagation(); closeFileTab(path); });
            tab.appendChild(close);

            tab.addEventListener('click', () => switchToFile(path));
            tabsBar.appendChild(tab);
        }
    }

    // ── File Management ────────────────────────────────────────────────
    async function openFile(path, name) {
        if (openFiles.has(path)) { switchToFile(path); return; }
        try {
            const content = await readFile(path);
            const lang = getLang(name);
            const model = monacoInstance.editor.createModel(content, lang);
            const fileEntry = { model, viewState: null, isDirty: false, originalContent: content };
            model.onDidChangeContent(() => {
                // Use fileEntry directly instead of path lookup — survives rename
                const was = fileEntry.isDirty;
                fileEntry.isDirty = model.getValue() !== fileEntry.originalContent;
                if (was !== fileEntry.isDirty) { renderTabs(); notifyDirty(); }
            });
            openFiles.set(path, fileEntry);
            switchToFile(path);
        } catch (err) { console.error('Open failed:', err); }
    }

    function switchToFile(path) {
        if (!openFiles.has(path)) return;
        if (activeFilePath && openFiles.has(activeFilePath))
            openFiles.get(activeFilePath).viewState = editor.saveViewState();
        activeFilePath = path;
        const f = openFiles.get(path);
        editor.setModel(f.model);
        if (f.viewState) editor.restoreViewState(f.viewState);
        editor.focus();
        document.getElementById('editor-container').classList.add('visible');
        document.getElementById('welcome').classList.remove('welcome-visible');
        renderTabs();
        selectedTreePath = path;
        highlightSelected();
        notifyActive(path.split('/').pop());
    }

    function closeFileTab(path) {
        const f = openFiles.get(path);
        if (!f) return;
        if (f.isDirty && !confirm(`Discard unsaved changes in "${path.split('/').pop()}"?`)) return;
        f.model.dispose();
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
                notifyActive(null);
            }
        }
        renderTabs();
        notifyDirty();
    }

    async function saveActive() {
        if (!activeFilePath) return;
        const f = openFiles.get(activeFilePath);
        if (!f || !f.isDirty) return;
        try {
            const content = f.model.getValue();
            await writeFile(activeFilePath, content);
            f.originalContent = content;
            f.isDirty = false;
            renderTabs();
            notifyDirty();
        } catch (err) { console.error('Save failed:', err); }
    }

    // ── Sidebar Resize ─────────────────────────────────────────────────
    const sidebar = document.getElementById('sidebar');
    const handle = document.getElementById('sidebar-resize-handle');
    let resizing = false;

    handle.addEventListener('mousedown', (e) => { resizing = true; document.body.style.cursor = 'col-resize'; e.preventDefault(); });
    document.addEventListener('mousemove', (e) => { if (resizing) sidebar.style.width = Math.max(140, Math.min(400, e.clientX)) + 'px'; });
    document.addEventListener('mouseup', () => { if (resizing) { resizing = false; document.body.style.cursor = ''; if (editor) editor.layout(); } });

    // ── Keyboard Shortcuts ─────────────────────────────────────────────
    document.addEventListener('keydown', (e) => {
        const mod = e.metaKey || e.ctrlKey;
        if (mod && e.key === 's') { e.preventDefault(); saveActive(); }
        if (mod && e.key === 'w') { e.preventDefault(); if (activeFilePath) closeFileTab(activeFilePath); }
        if (mod && e.key === 'n') { e.preventDefault(); promptNewFile(''); }
        if (e.key === 'F2' && selectedTreePath) {
            e.preventDefault();
            const row = treeEl.querySelector(`[data-path="${CSS.escape(selectedTreePath)}"]`);
            if (row) startInlineRename(row, selectedTreePath, selectedTreePath.split('/').pop());
        }
        if (e.key === 'Delete' && selectedTreePaths.size > 0) {
            const paths = Array.from(selectedTreePaths);
            const label = paths.length === 1 ? paths[0].split('/').pop() : `${paths.length} items`;
            if (!confirm(`Delete "${label}"?`)) return;
            (async () => {
                for (const p of paths) {
                    try {
                        await deleteFile(p);
                        if (openFiles.has(p)) closeFileTab(p);
                    } catch (err) { console.error('Delete failed:', err); }
                }
                selectedTreePaths.clear();
                await refreshTree();
                lastTreeSnapshot = await buildSnapshot('');
            })();
        }
    });

    // ── Right-click on empty area ──────────────────────────────────────
    treeEl.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        showContextMenu(e.clientX, e.clientY, '', true, '');
    });

    // ── Mouse-based Drag-and-Drop ─────────────────────────────────────
    let autoExpandTimer = null;
    let autoExpandTarget = null;
    let currentDropTargetRow = null;
    const DRAG_THRESHOLD = 5; // px before drag starts

    function findRowForDir(dirPath) {
        if (!dirPath) return null;
        return treeEl.querySelector(`.tree-row[data-path="${CSS.escape(dirPath)}"][data-is-dir="1"]`);
    }

    function clearDropTarget() {
        treeEl.querySelectorAll('.drop-target').forEach(el => el.classList.remove('drop-target'));
        currentDropTargetRow = null;
        if (autoExpandTimer) { clearTimeout(autoExpandTimer); autoExpandTimer = null; autoExpandTarget = null; }
    }

    function findRowAtPoint(x, y) {
        const rows = treeEl.querySelectorAll('.tree-row');
        for (const row of rows) {
            const rect = row.getBoundingClientRect();
            if (y >= rect.top && y <= rect.bottom && x >= rect.left && x <= rect.right) return row;
        }
        return null;
    }

    let dragSourcePaths = new Set(); // multi-drag

    document.addEventListener('mousemove', (e) => {
        if (!dragMouseStart) return;

        // Start drag after threshold
        if (!isDragging) {
            const dx = e.clientX - dragMouseStart.x;
            const dy = e.clientY - dragMouseStart.y;
            if (Math.abs(dx) < DRAG_THRESHOLD && Math.abs(dy) < DRAG_THRESHOLD) return;
            isDragging = true;
            dragSourcePaths = dragMouseStart.paths;
            dragSourcePath = Array.from(dragSourcePaths)[0]; // primary for validation
            // Mark all dragged rows
            for (const p of dragSourcePaths) {
                const r = treeEl.querySelector(`.tree-row[data-path="${CSS.escape(p)}"]`);
                if (r) r.classList.add('cut');
            }
            document.body.style.cursor = 'grabbing';
        }

        // Find row under cursor
        const targetRow = findRowAtPoint(e.clientX, e.clientY);
        if (!targetRow) {
            clearDropTarget();
            return;
        }

        const targetPath = targetRow.dataset.path;
        const targetIsDir = targetRow.dataset.isDir === '1';
        // Files bubble to parent
        const dropDir = targetIsDir ? targetPath : (targetPath.substring(0, targetPath.lastIndexOf('/')) || '');

        // Validate — can't drop into any of the dragged items
        let invalid = false;
        for (const sp of dragSourcePaths) {
            if (dropDir === sp || dropDir.startsWith(sp + '/')) { invalid = true; break; }
        }
        if (invalid) { clearDropTarget(); return; }

        const dirRow = targetIsDir ? targetRow : findRowForDir(dropDir);
        if (dirRow !== currentDropTargetRow) {
            clearDropTarget();
            currentDropTargetRow = dirRow;
            if (dirRow) dirRow.classList.add('drop-target');

            // Auto-expand collapsed folders after 500ms
            if (targetIsDir && !expandedDirs.has(targetPath)) {
                autoExpandTarget = targetPath;
                autoExpandTimer = setTimeout(async () => {
                    if (autoExpandTarget === targetPath && isDragging) {
                        expandedDirs.add(targetPath);
                        await refreshTree();
                    }
                }, 500);
            }
        }
    });

    document.addEventListener('mouseup', async (e) => {
        if (!isDragging) {
            dragMouseStart = null;
            return;
        }

        // Clean up visual state
        treeEl.querySelectorAll('.cut').forEach(el => el.classList.remove('cut'));
        document.body.style.cursor = '';
        clearDropTarget();

        const targetRow = findRowAtPoint(e.clientX, e.clientY);
        let dropDir = '';
        if (targetRow) {
            const targetPath = targetRow.dataset.path;
            const targetIsDir = targetRow.dataset.isDir === '1';
            dropDir = targetIsDir ? targetPath : (targetPath.substring(0, targetPath.lastIndexOf('/')) || '');
        }

        // De-duplicate nested selections: if parent and child are both selected, only move parent
        const sources = Array.from(dragSourcePaths)
            .sort((a, b) => a.length - b.length)
            .filter((src, i, arr) => !arr.slice(0, i).some(parent => src.startsWith(parent + '/')));
        dragSourcePath = null;
        dragSourcePaths = new Set();
        dragMouseStart = null;
        isDragging = false;

        if (sources.length === 0) return;

        // Validate — can't drop into any source
        for (const src of sources) {
            if (dropDir === src || dropDir.startsWith(src + '/')) return;
        }

        // Move all selected items
        try {
            for (const src of sources) {
                const sourceName = src.split('/').pop();
                const newPath = dropDir ? dropDir + '/' + sourceName : sourceName;
                if (newPath === src) continue;
                await renameFile(src, newPath);
                // Update open file references
                const updates = [];
                for (const [op, file] of openFiles) {
                    if (op === src || op.startsWith(src + '/')) {
                        updates.push([op, newPath + op.substring(src.length), file]);
                    }
                }
                for (const [o, n, f] of updates) { openFiles.delete(o); openFiles.set(n, f); if (activeFilePath === o) activeFilePath = n; }
            }
            renderTabs();
            if (dropDir) expandedDirs.add(dropDir);
            await refreshTree();
            lastTreeSnapshot = await buildSnapshot('');
        } catch (err) { console.error('Move failed:', err); }
    });

    // ── Monaco Init ────────────────────────────────────────────────────
    require.config({ paths: { vs: 'https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs' } });

    require(['vs/editor/editor.main'], async function (monaco) {
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

        // Initial load
        await refreshGitStatus();
        await renderTree(treeEl, '', 0);
        lastTreeSnapshot = await buildSnapshot('');
        setupHeader();
        startWatching();

        document.getElementById('project-name').textContent = 'EXPLORER';
    });
})();
