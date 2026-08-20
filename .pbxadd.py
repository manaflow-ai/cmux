#!/usr/bin/env python3
"""Session helper: register app-target Swift files in cmux.xcodeproj.

Mirrors the existing single-file pattern (BuildFile + FileReference + group
child + Sources phase) using SidebarCreationContextColumn.swift's entries as
anchors. Not shipped; deleted before the PR.
"""
import hashlib
import re
import sys

PBX = 'cmux.xcodeproj/project.pbxproj'
ANCHOR = 'SidebarMachineColumnView.swift'
TEST_ANCHOR = None


def uid(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def add(path: str, s: str) -> str:
    name = path.split('/')[-1]
    file_ref = uid('fileref:' + path)
    build = uid('buildfile:' + path)
    if file_ref in s:
        print(f'skip (already added): {path}')
        return s

    # 1. PBXBuildFile line after anchor's
    anchor_build = re.search(
        r'\n(\t\t[0-9A-F]{24} /\* ' + re.escape(ANCHOR) +
        r' in Sources \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24}) /\* ' +
        re.escape(ANCHOR) + r' \*/; \};)', s)
    assert anchor_build, 'anchor build file not found'
    line = ('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s '
            '/* %s */; };' % (build, name, file_ref, name))
    s = s.replace(anchor_build.group(1), anchor_build.group(1) + '\n' + line, 1)

    # 2. PBXFileReference after anchor's
    anchor_ref = re.search(
        r'\n(\t\t[0-9A-F]{24} /\* ' + re.escape(ANCHOR) +
        r' \*/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; '
        r'path = [^;]+; sourceTree = "<group>"; \};)', s)
    assert anchor_ref, 'anchor file ref not found'
    line = ('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = '
            'sourcecode.swift; path = %s; sourceTree = "<group>"; };'
            % (file_ref, name, path))
    s = s.replace(anchor_ref.group(1), anchor_ref.group(1) + '\n' + line, 1)

    # 3. group child + 4. sources phase, both after anchor lines
    for suffix, ref in ((' */,', file_ref), (' in Sources */,', build)):
        pat = re.compile(r'\n(\t+[0-9A-F]{24} /\* ' + re.escape(ANCHOR) +
                         re.escape(suffix.replace(',', '')) + r',)')
        m = pat.search(s)
        assert m, f'anchor list entry not found for suffix {suffix!r}'
        indent = re.match(r'\n(\t+)', m.group(0)).group(1)
        label = name + suffix.replace(',', '')
        line = f'{indent}{ref} /* {label},'
        s = s.replace(m.group(1), m.group(1) + '\n' + line.rstrip(), 1)
    return s


def main():
    with open(PBX) as f:
        s = f.read()
    for path in sys.argv[1:]:
        s = add(path, s)
        print('registered', path)
    with open(PBX, 'w') as f:
        f.write(s)


if __name__ == '__main__':
    main()
