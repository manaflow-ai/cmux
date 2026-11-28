// No code. This target exists so the CmuxGhosttyKit product carries the
// linker settings libghostty's static archive needs: it contains C++
// objects (glslang), so every binary that links GhosttyNextKit must link
// libc++. A binary target cannot declare linker settings itself.
