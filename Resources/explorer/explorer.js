// cmux Sidebar Explorer — multi-root file tree with external file opening
// Swift bridge via window.webkit.messageHandlers.cmuxExplorer

(function () {
    'use strict';

    let requestCounter = 0;
    const pendingRequests = new Map();
    let roots = []; // [{name, rootIndex}]
    let gitStatusMaps = new Map(); // rootIndex -> Map(path -> status)
    let gitIgnoredSets = new Map(); // rootIndex -> Set(path)
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
        },
        // Called from Swift to set/update the root folders
        setRoots(newRoots) {
            // newRoots = [{name: "cmux", rootIndex: 0}, {name: "web", rootIndex: 1}]
            roots = newRoots;
            window.cmuxExplorer._lastRoots = newRoots;
            fullRefresh();
        },
        // Called from Swift on FSEvents file change — diffed, no flash
        refresh() {
            if (roots.length > 0) diffRefresh();
        }
    };

    function post(action, params = {}) {
        return new Promise((resolve, reject) => {
            const requestId = 'r' + (++requestCounter);
            pendingRequests.set(requestId, { resolve, reject });
            window.webkit.messageHandlers.cmuxExplorer.postMessage({ action, requestId, ...params });
        });
    }

    const readDir = (rootIndex, path) => post('readDir', { rootIndex, path });
    const createFile = (rootIndex, path) => post('createFile', { rootIndex, path });
    const createDir = (rootIndex, path) => post('createDir', { rootIndex, path });
    const deleteFile = (rootIndex, path) => post('deleteFile', { rootIndex, path });
    const renameFile = (rootIndex, oldPath, newPath) => post('renameFile', { rootIndex, oldPath, newPath });
    const getGitStatus = (rootIndex) => post('gitStatus', { rootIndex });

    function openFileExternal(rootIndex, path) {
        window.webkit.messageHandlers.cmuxExplorer.postMessage({
            action: 'openFileExternal', rootIndex, path
        });
    }

    function pinFileExternal(rootIndex, path) {
        window.webkit.messageHandlers.cmuxExplorer.postMessage({
            action: 'pinFileExternal', rootIndex, path
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
    async function refreshGitStatus(rootIndex) {
        try {
            const result = await getGitStatus(rootIndex);
            const statusMap = new Map();
            const ignoredSet = new Set();
            for (const f of (result.files || [])) statusMap.set(f.path, f.status);
            for (const f of (result.ignored || [])) ignoredSet.add(f.path);
            gitStatusMaps.set(rootIndex, statusMap);
            gitIgnoredSets.set(rootIndex, ignoredSet);
        } catch { /* git not available */ }
    }

    function getGitStatusForPath(rootIndex, path) {
        const m = gitStatusMaps.get(rootIndex);
        if (m && m.has(path)) return m.get(path);
        // Check if this path or any parent is ignored
        const s = gitIgnoredSets.get(rootIndex);
        if (s) {
            if (s.has(path)) return 'ignored';
            // Check parent paths (e.g. node_modules is ignored → node_modules/foo is too)
            const parts = path.split('/');
            for (let i = 1; i < parts.length; i++) {
                if (s.has(parts.slice(0, i).join('/'))) return 'ignored';
            }
        }
        return null;
    }

    function getFolderGitStatus(rootIndex, folderPath) {
        // Check if the folder itself is ignored
        const s = gitIgnoredSets.get(rootIndex);
        if (s) {
            if (s.has(folderPath)) return 'ignored';
            const parts = folderPath.split('/');
            for (let i = 1; i < parts.length; i++) {
                if (s.has(parts.slice(0, i).join('/'))) return 'ignored';
            }
        }
        const m = gitStatusMaps.get(rootIndex);
        if (!m) return null;
        const prefix = folderPath ? folderPath + '/' : '';
        let dominated = null;
        // VS Code priority: conflict > modified > deleted > added > untracked > renamed
        const priority = { conflict: 6, modified: 5, deleted: 4, added: 3, untracked: 2, renamed: 1 };
        for (const [path, status] of m) {
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
    const expandedDirs = new Set(); // "rootIndex:path" keys
    const expandedRoots = new Set(); // rootIndex values

    function dirKey(rootIndex, path) { return rootIndex + ':' + path; }

    async function renderTree(parentEl, rootIndex, path, depth) {
        let entries;
        try { entries = await readDir(rootIndex, path); } catch { return; }
        entries.sort((a, b) => {
            if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
            return a.name.localeCompare(b.name);
        });

        for (const entry of entries) {
            const fullPath = path ? path + '/' + entry.name : entry.name;
            const dk = dirKey(rootIndex, fullPath);
            const isExpanded = expandedDirs.has(dk);
            const gitStatus = entry.isDirectory
                ? getFolderGitStatus(rootIndex, fullPath)
                : getGitStatusForPath(rootIndex, fullPath);

            const row = document.createElement('div');
            row.className = 'tree-row';
            row.dataset.path = dk;
            row.dataset.rootIndex = rootIndex;
            row.dataset.relPath = fullPath;
            row.dataset.isDir = entry.isDirectory ? '1' : '0';
            if (dk === selectedTreePath) row.classList.add('selected');

            const indent = document.createElement('span');
            indent.className = 'tree-indent';
            for (let i = 0; i < depth; i++) {
                const guide = document.createElement('span');
                guide.className = 'indent-guide active';
                indent.appendChild(guide);
            }
            row.appendChild(indent);

            const twistie = document.createElement('span');
            twistie.className = 'tree-twistie';
            if (entry.isDirectory) {
                twistie.textContent = '\uEAB6';
                if (isExpanded) twistie.classList.add('expanded');
            } else {
                twistie.classList.add('hidden');
            }
            row.appendChild(twistie);

            const icon = document.createElement('span');
            icon.className = 'tree-icon ' + fileIconClass(entry.name, entry.isDirectory, isExpanded);
            icon.textContent = fileCodiconChar(entry.name, entry.isDirectory, isExpanded);
            row.appendChild(icon);

            const label = document.createElement('span');
            label.className = 'tree-label';
            if (gitStatus) label.classList.add(gitLabelClass(gitStatus));
            label.textContent = entry.name;
            row.appendChild(label);

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
                    await renderTree(children, rootIndex, fullPath, depth + 1);
                }
                parentEl.appendChild(children);

                row.addEventListener('click', async (e) => {
                    e.stopPropagation();
                    handleSelection(dk, e);
                    if (expandedDirs.has(dk)) {
                        expandedDirs.delete(dk);
                        twistie.classList.remove('expanded');
                        children.classList.remove('expanded');
                        children.innerHTML = '';
                        icon.className = 'tree-icon ' + fileIconClass(entry.name, true, false);
                        icon.textContent = fileCodiconChar(entry.name, true, false);
                    } else {
                        expandedDirs.add(dk);
                        twistie.classList.add('expanded');
                        children.innerHTML = '';
                        await renderTree(children, rootIndex, fullPath, depth + 1);
                        children.classList.add('expanded');
                        icon.className = 'tree-icon ' + fileIconClass(entry.name, true, true);
                        icon.textContent = fileCodiconChar(entry.name, true, true);
                    }
                });
            } else {
                row.addEventListener('click', (e) => {
                    e.stopPropagation();
                    handleSelection(dk, e);
                    if (!e.shiftKey && !e.metaKey && !e.ctrlKey) {
                        openFileExternal(rootIndex, fullPath);
                    }
                });
            }

            row.addEventListener('contextmenu', (e) => {
                e.preventDefault();
                e.stopPropagation();
                if (!selectedTreePaths.has(dk)) selectSingle(dk);
                showContextMenu(e.clientX, e.clientY, rootIndex, fullPath, entry.isDirectory, entry.name);
            });

            row.addEventListener('dblclick', (e) => {
                e.preventDefault();
                e.stopPropagation();
                if (entry.isDirectory) return;
                pinFileExternal(rootIndex, fullPath);
            });
        }
    }

    // ── Root Folder Rendering ──────────────────────────────────────────
    async function renderAllRoots() {
        treeEl.innerHTML = '';
        if (roots.length === 1) {
            // Single root — no wrapper, render tree directly
            expandedRoots.add(roots[0].rootIndex);
            await renderTree(treeEl, roots[0].rootIndex, '', 0);
        } else {
            // Multi-root — each root gets a collapsible header
            for (const root of roots) {
                const isExpanded = expandedRoots.has(root.rootIndex);
                const section = document.createElement('div');
                section.className = 'root-section';

                const header = document.createElement('div');
                header.className = 'tree-row root-header';
                header.dataset.rootIndex = root.rootIndex;

                const twistie = document.createElement('span');
                twistie.className = 'tree-twistie';
                twistie.textContent = '\uEAB6';
                if (isExpanded) twistie.classList.add('expanded');
                header.appendChild(twistie);

                const icon = document.createElement('span');
                icon.className = 'tree-icon icon-folder' + (isExpanded ? '-open' : '');
                icon.textContent = fileCodiconChar(root.name, true, isExpanded);
                header.appendChild(icon);

                const label = document.createElement('span');
                label.className = 'tree-label root-label';
                label.textContent = root.name;
                header.appendChild(label);

                section.appendChild(header);

                const children = document.createElement('div');
                children.className = 'tree-children';
                if (isExpanded) {
                    children.classList.add('expanded');
                    await renderTree(children, root.rootIndex, '', 1);
                }
                section.appendChild(children);

                header.addEventListener('click', async () => {
                    if (expandedRoots.has(root.rootIndex)) {
                        expandedRoots.delete(root.rootIndex);
                        twistie.classList.remove('expanded');
                        children.classList.remove('expanded');
                        children.innerHTML = '';
                        icon.className = 'tree-icon icon-folder';
                        icon.textContent = fileCodiconChar(root.name, true, false);
                    } else {
                        expandedRoots.add(root.rootIndex);
                        twistie.classList.add('expanded');
                        children.innerHTML = '';
                        await renderTree(children, root.rootIndex, '', 1);
                        children.classList.add('expanded');
                        icon.className = 'tree-icon icon-folder-open';
                        icon.textContent = fileCodiconChar(root.name, true, true);
                    }
                });

                treeEl.appendChild(section);
            }
        }
    }

    function highlightSelected() {
        treeEl.querySelectorAll('.tree-row').forEach(r => {
            const key = r.dataset.path || '';
            r.classList.toggle('selected', selectedTreePaths.has(key));
            r.classList.toggle('focused', key === selectedTreePath);
        });
    }

    function getVisiblePaths() {
        return Array.from(treeEl.querySelectorAll('.tree-row[data-path]')).map(r => r.dataset.path);
    }

    function selectSingle(key) {
        selectedTreePaths.clear();
        selectedTreePaths.add(key);
        selectedTreePath = key;
        lastClickedPath = key;
        highlightSelected();
    }

    function selectToggle(key) {
        if (selectedTreePaths.has(key)) selectedTreePaths.delete(key);
        else selectedTreePaths.add(key);
        selectedTreePath = key;
        lastClickedPath = key;
        highlightSelected();
    }

    function selectRange(toKey) {
        const paths = getVisiblePaths();
        const fromIdx = paths.indexOf(lastClickedPath);
        const toIdx = paths.indexOf(toKey);
        if (fromIdx === -1 || toIdx === -1) { selectSingle(toKey); return; }
        for (let i = Math.min(fromIdx, toIdx); i <= Math.max(fromIdx, toIdx); i++) {
            selectedTreePaths.add(paths[i]);
        }
        selectedTreePath = toKey;
        highlightSelected();
    }

    function handleSelection(key, e) {
        if (e.shiftKey && lastClickedPath) selectRange(key);
        else if (e.metaKey || e.ctrlKey) selectToggle(key);
        else selectSingle(key);
    }

    // ── Context Menu ───────────────────────────────────────────────────
    let ctxMenu = null;
    function removeCtxMenu() { if (ctxMenu) { ctxMenu.remove(); ctxMenu = null; } }
    document.addEventListener('click', removeCtxMenu);

    function showContextMenu(x, y, rootIndex, targetPath, isDir, name) {
        removeCtxMenu();
        const menu = document.createElement('div');
        menu.className = 'context-menu';
        menu.style.left = x + 'px';
        menu.style.top = y + 'px';

        const parentDir = isDir ? targetPath : targetPath.substring(0, targetPath.lastIndexOf('/')) || '';
        const items = [
            { label: 'New File...', action: () => promptNewFile(rootIndex, parentDir) },
            { label: 'New Folder...', action: () => promptNewFolder(rootIndex, parentDir) },
            { separator: true },
            { label: 'Rename', shortcut: 'F2', action: () => {
                const dk = dirKey(rootIndex, targetPath);
                const row = treeEl.querySelector(`[data-path="${CSS.escape(dk)}"]`);
                if (row) startInlineRename(row, rootIndex, targetPath, name);
            }},
            { label: 'Delete', action: () => confirmDelete(rootIndex, targetPath, name, isDir) },
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

    async function confirmDelete(rootIndex, path, name, isDir) {
        if (!confirm(`Delete "${name}"?`)) return;
        try {
            await deleteFile(rootIndex, path);
            await renderAllRoots();
        } catch (err) { console.error('Delete failed:', err); }
    }

    // ── Inline Rename ──────────────────────────────────────────────────
    function startInlineRename(row, rootIndex, path, name) {
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
                renameFile(rootIndex, path, newPath).then(async () => {
                    await renderAllRoots();
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
    function promptNewFile(rootIndex, parentDir) { promptInlineCreate(rootIndex, parentDir, false); }
    function promptNewFolder(rootIndex, parentDir) { promptInlineCreate(rootIndex, parentDir, true); }

    function promptInlineCreate(rootIndex, parentDir, isDir) {
        const dk = parentDir ? dirKey(rootIndex, parentDir) : null;
        if (parentDir && !expandedDirs.has(dk)) {
            expandedDirs.add(dk);
            renderAllRoots().then(() => promptInlineCreate(rootIndex, parentDir, isDir));
            return;
        }
        inlineInputActive = true;
        let container = treeEl;
        if (dk) {
            const parentRow = treeEl.querySelector(`[data-path="${CSS.escape(dk)}"]`);
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
            const op = isDir ? createDir(rootIndex, fullPath) : createFile(rootIndex, fullPath);
            op.then(async () => {
                await renderAllRoots();
                if (!isDir) openFileExternal(rootIndex, fullPath);
            }).catch(err => console.error('Create failed:', err));
        }
        input.addEventListener('blur', commit);
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
            if (e.key === 'Escape') { inlineInputActive = false; inputRow.remove(); }
        });
    }

    // ── Header ─────────────────────────────────────────────────────────
    function setupHeader() {
        const header = document.getElementById('sidebar-header');
        const btnGroup = document.createElement('div');
        btnGroup.className = 'header-buttons';

        const refreshBtn = document.createElement('button');
        refreshBtn.className = 'header-btn';
        refreshBtn.title = 'Refresh';
        refreshBtn.textContent = '\uEB37';
        refreshBtn.addEventListener('click', () => fullRefresh());

        btnGroup.appendChild(refreshBtn);
        header.appendChild(btnGroup);
    }

    async function fullRefresh() {
        for (const root of roots) {
            await refreshGitStatus(root.rootIndex);
        }
        await renderAllRoots();
        document.getElementById('project-name').textContent = 'EXPLORER';
    }

    // Lightweight refresh: update git status badges in-place without re-rendering the tree.
    // Only does a full re-render if the directory structure actually changed.
    async function diffRefresh() {
        // Snapshot current expanded dirs' entry names before refresh
        const oldSnapshots = new Map();
        for (const root of roots) {
            if (!expandedRoots.has(root.rootIndex)) continue;
            oldSnapshots.set(root.rootIndex, await quickSnapshot(root.rootIndex));
            await refreshGitStatus(root.rootIndex);
        }

        // Check if any directory structure changed
        let structureChanged = false;
        for (const [rootIndex, oldSnap] of oldSnapshots) {
            const newSnap = await quickSnapshot(rootIndex);
            if (newSnap !== oldSnap) { structureChanged = true; break; }
        }

        if (structureChanged) {
            await renderAllRoots();
        } else {
            // Just update git badges/labels in-place
            treeEl.querySelectorAll('.tree-row[data-root-index]').forEach(row => {
                const ri = parseInt(row.dataset.rootIndex);
                const relPath = row.dataset.relPath;
                if (relPath === undefined) return;
                const isDir = row.dataset.isDir === '1';
                const gitStatus = isDir
                    ? getFolderGitStatus(ri, relPath)
                    : getGitStatusForPath(ri, relPath);

                // Update label class
                const label = row.querySelector('.tree-label');
                if (label) {
                    label.className = 'tree-label';
                    if (gitStatus) label.classList.add(gitLabelClass(gitStatus));
                }

                // Update badge
                const oldBadge = row.querySelector('.tree-badge');
                if (oldBadge) oldBadge.remove();
                if (gitStatus && gitStatus !== 'ignored') {
                    if (isDir) {
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
            });
        }
    }

    // Quick snapshot of entry names for a root (only expanded dirs, no content)
    async function quickSnapshot(rootIndex) {
        return await buildEntryList(rootIndex, '');
    }

    async function buildEntryList(rootIndex, path) {
        try {
            const entries = await readDir(rootIndex, path);
            let s = '';
            entries.sort((a, b) => a.name.localeCompare(b.name));
            for (const e of entries) {
                const fp = path ? path + '/' + e.name : e.name;
                s += fp + (e.isDirectory ? '/' : '') + '\n';
                const dk = dirKey(rootIndex, fp);
                if (e.isDirectory && expandedDirs.has(dk)) {
                    s += await buildEntryList(rootIndex, fp);
                }
            }
            return s;
        } catch { return ''; }
    }

    // ── Init ───────────────────────────────────────────────────────────
    setupHeader();
    document.getElementById('project-name').textContent = 'EXPLORER';
})();
