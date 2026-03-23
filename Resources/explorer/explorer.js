// cmux Sidebar Explorer — file tree with external file opening
// Swift bridge via window.webkit.messageHandlers.cmuxExplorer

(function () {
    'use strict';

    let requestCounter = 0;
    const pendingRequests = new Map();
    let lastTreeSnapshot = '';
    let gitStatusMap = new Map();
    let gitIgnoredSet = new Set();
    let selectedTreePaths = new Set();
    let lastClickedPath = null;
    let selectedTreePath = null;
    let inlineInputActive = false;

    // ── Swift Bridge ───────────────────────────────────────────────────
    window.cmuxExplorer = {
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
        updateTheme(sidebarBg, fg, borderColor, hoverBg, selectedBg, indentGuide) {
            const r = document.documentElement.style;
            r.setProperty('--sidebar-bg', sidebarBg);
            r.setProperty('--sidebar-fg', fg);
            r.setProperty('--sidebar-border', borderColor);
            r.setProperty('--sidebar-header-bg', sidebarBg);
            r.setProperty('--list-hover-bg', hoverBg);
            r.setProperty('--list-inactive-selection-bg', selectedBg);
            r.setProperty('--tree-indent-guide', indentGuide);
            r.setProperty('--input-bg', hoverBg);
            r.setProperty('--input-border', borderColor);
            r.setProperty('--input-fg', fg);
            r.setProperty('--context-menu-bg', sidebarBg);
            document.body.style.background = sidebarBg;
        }
    };

    function post(action, params = {}) {
        return new Promise((resolve, reject) => {
            const requestId = 'r' + (++requestCounter);
            pendingRequests.set(requestId, { resolve, reject });
            window.webkit.messageHandlers.cmuxExplorer.postMessage({ action, requestId, ...params });
        });
    }

    const readDir = (path) => post('readDir', { path });
    const createFile = (path) => post('createFile', { path });
    const createDir = (path) => post('createDir', { path });
    const deleteFile = (path) => post('deleteFile', { path });
    const renameFile = (oldPath, newPath) => post('renameFile', { oldPath, newPath });
    const getGitStatus = () => post('gitStatus', {});

    function openFileExternal(path) {
        window.webkit.messageHandlers.cmuxExplorer.postMessage({
            action: 'openFileExternal',
            path: path
        });
    }

    function pinFileExternal(path) {
        window.webkit.messageHandlers.cmuxExplorer.postMessage({
            action: 'pinFileExternal',
            path: path
        });
    }

    // ── File Icons ─────────────────────────────────────────────────────
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
        if (isDir) return isOpen ? '\uEAF7' : '\uEAF6';
        return '\uEB60';
    }

    // ── Git Status ─────────────────────────────────────────────────────
    async function refreshGitStatus() {
        try {
            const result = await getGitStatus();
            gitStatusMap.clear();
            gitIgnoredSet.clear();
            for (const f of (result.files || [])) gitStatusMap.set(f.path, f.status);
            for (const f of (result.ignored || [])) gitIgnoredSet.add(f.path);
        } catch { /* git not available */ }
    }

    function getGitStatusForPath(path) {
        if (gitStatusMap.has(path)) return gitStatusMap.get(path);
        if (gitIgnoredSet.has(path)) return 'ignored';
        return null;
    }

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
    function gitLabelClass(status) { return status ? 'git-' + status : ''; }
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
                twistie.textContent = '\uEAB6';
                if (isExpanded) twistie.classList.add('expanded');
            } else {
                twistie.classList.add('hidden');
            }
            row.appendChild(twistie);

            // Icon
            const icon = document.createElement('span');
            icon.className = 'tree-icon ' + fileIconClass(entry.name, entry.isDirectory, isExpanded);
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
                    if (!e.shiftKey && !e.metaKey && !e.ctrlKey) {
                        openFileExternal(fullPath);
                    }
                });
            }

            // Context menu
            row.addEventListener('contextmenu', (e) => {
                e.preventDefault();
                e.stopPropagation();
                if (!selectedTreePaths.has(fullPath)) selectSingle(fullPath);
                showContextMenu(e.clientX, e.clientY, fullPath, entry.isDirectory, entry.name);
            });

            // Double-click: files → pin editor tab, directories → rename
            row.addEventListener('dblclick', (e) => {
                e.preventDefault();
                e.stopPropagation();
                if (entry.isDirectory) return;
                // Double-click pins the file (opens it permanently)
                pinFileExternal(fullPath);
            });
        }
    }

    function highlightSelected() {
        treeEl.querySelectorAll('.tree-row').forEach(r => {
            r.classList.toggle('selected', selectedTreePaths.has(r.dataset.path));
            r.classList.toggle('focused', r.dataset.path === selectedTreePath);
        });
    }

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
        if (selectedTreePaths.has(path)) selectedTreePaths.delete(path);
        else selectedTreePaths.add(path);
        selectedTreePath = path;
        lastClickedPath = path;
        highlightSelected();
    }

    function selectRange(toPath) {
        const paths = getVisiblePaths();
        const fromIdx = paths.indexOf(lastClickedPath);
        const toIdx = paths.indexOf(toPath);
        if (fromIdx === -1 || toIdx === -1) { selectSingle(toPath); return; }
        for (let i = Math.min(fromIdx, toIdx); i <= Math.max(fromIdx, toIdx); i++) {
            selectedTreePaths.add(paths[i]);
        }
        selectedTreePath = toPath;
        highlightSelected();
    }

    function handleSelection(path, e) {
        if (e.shiftKey && lastClickedPath) selectRange(path);
        else if (e.metaKey || e.ctrlKey) selectToggle(path);
        else selectSingle(path);
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
        if (pollRunning) return;
        pollRunning = true;
        try {
            const snap = await buildSnapshot('');
            const oldGitSnap = lastGitSnapshot;
            await refreshGitStatus();
            const gitSnap = Array.from(gitStatusMap.entries()).sort().map(e => e[0] + ':' + e[1]).join('\n')
                + '\n---\n' + Array.from(gitIgnoredSet).sort().join('\n');
            lastGitSnapshot = gitSnap;
            if (snap !== lastTreeSnapshot || gitSnap !== oldGitSnap) {
                lastTreeSnapshot = snap;
                await refreshTree();
            }
        } finally { pollRunning = false; }
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
            { label: 'Copy Path', action: () => navigator.clipboard.writeText(targetPath).catch(() => {}) },
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
        const r = menu.getBoundingClientRect();
        if (r.right > window.innerWidth) menu.style.left = (window.innerWidth - r.width - 4) + 'px';
        if (r.bottom > window.innerHeight) menu.style.top = (window.innerHeight - r.height - 4) + 'px';
    }

    async function confirmDelete(path, name, isDir) {
        if (!confirm(`Delete "${name}"?`)) return;
        try {
            await deleteFile(path);
            await refreshTree();
            lastTreeSnapshot = await buildSnapshot('');
        } catch (err) { console.error('Delete failed:', err); }
    }

    // ── Inline Rename ──────────────────────────────────────────────────
    function startInlineRename(row, path, name) {
        const label = row.querySelector('.tree-label');
        if (!label) return;
        inlineInputActive = true;
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'tree-inline-input';
        input.value = name;
        const dotIdx = name.lastIndexOf('.');
        label.style.display = 'none';
        row.appendChild(input);
        input.focus();
        if (dotIdx > 0) input.setSelectionRange(0, dotIdx);
        else input.select();

        function commit() {
            inlineInputActive = false;
            const newName = input.value.trim();
            input.remove();
            label.style.display = '';
            if (newName && newName !== name && !newName.includes('/')) {
                const parentDir = path.substring(0, path.lastIndexOf('/'));
                const newPath = parentDir ? parentDir + '/' + newName : newName;
                renameFile(path, newPath).then(async () => {
                    await refreshTree();
                    lastTreeSnapshot = await buildSnapshot('');
                }).catch(err => console.error('Rename failed:', err));
            }
        }
        input.addEventListener('blur', commit);
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
            if (e.key === 'Escape') { inlineInputActive = false; input.remove(); label.style.display = ''; }
        });
    }

    // ── New File / Folder ──────────────────────────────────────────────
    function promptNewFile(parentDir) {
        promptInlineCreate(parentDir, false);
    }
    function promptNewFolder(parentDir) {
        promptInlineCreate(parentDir, true);
    }

    function promptInlineCreate(parentDir, isDir) {
        if (parentDir && !expandedDirs.has(parentDir)) {
            expandedDirs.add(parentDir);
            refreshTree().then(() => promptInlineCreate(parentDir, isDir));
            return;
        }
        inlineInputActive = true;
        let container = treeEl;
        if (parentDir) {
            const parentRow = treeEl.querySelector(`[data-path="${CSS.escape(parentDir)}"]`);
            if (parentRow) {
                const children = parentRow.nextElementSibling;
                if (children && children.classList.contains('tree-children')) container = children;
            }
        }
        const inputRow = document.createElement('div');
        inputRow.className = 'tree-row tree-input-row';
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'tree-inline-input';
        input.placeholder = isDir ? 'Folder name' : 'File name';
        inputRow.appendChild(input);
        container.insertBefore(inputRow, container.firstChild);
        input.focus();

        function commit() {
            inlineInputActive = false;
            const name = input.value.trim();
            inputRow.remove();
            if (!name || name.includes('/')) return;
            const fullPath = parentDir ? parentDir + '/' + name : name;
            const op = isDir ? createDir(fullPath) : createFile(fullPath);
            op.then(async () => {
                await refreshTree();
                lastTreeSnapshot = await buildSnapshot('');
                if (!isDir) openFileExternal(fullPath);
            }).catch(err => console.error('Create failed:', err));
        }
        input.addEventListener('blur', commit);
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
            if (e.key === 'Escape') { inlineInputActive = false; inputRow.remove(); }
        });
    }

    // ── Header Buttons ─────────────────────────────────────────────────
    function setupHeader() {
        const header = document.getElementById('sidebar-header');
        const btnGroup = document.createElement('div');
        btnGroup.className = 'header-buttons';

        const newFileBtn = document.createElement('button');
        newFileBtn.className = 'header-btn';
        newFileBtn.title = 'New File';
        newFileBtn.textContent = '\uEA7F';
        newFileBtn.addEventListener('click', () => promptNewFile(''));

        const newFolderBtn = document.createElement('button');
        newFolderBtn.className = 'header-btn';
        newFolderBtn.title = 'New Folder';
        newFolderBtn.textContent = '\uEA83';
        newFolderBtn.addEventListener('click', () => promptNewFolder(''));

        const refreshBtn = document.createElement('button');
        refreshBtn.className = 'header-btn';
        refreshBtn.title = 'Refresh';
        refreshBtn.textContent = '\uEB37';
        refreshBtn.addEventListener('click', async () => {
            lastTreeSnapshot = '';
            await refreshGitStatus();
            await refreshTree();
            lastTreeSnapshot = await buildSnapshot('');
        });

        btnGroup.appendChild(newFileBtn);
        btnGroup.appendChild(newFolderBtn);
        btnGroup.appendChild(refreshBtn);
        header.appendChild(btnGroup);
    }

    // ── Init ───────────────────────────────────────────────────────────
    async function init() {
        await refreshGitStatus();
        await renderTree(treeEl, '', 0);
        lastTreeSnapshot = await buildSnapshot('');
        setupHeader();
        setInterval(poll, 2000);
        document.getElementById('project-name').textContent = 'EXPLORER';
    }

    init();
})();
