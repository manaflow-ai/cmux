#include "CmuxNextSharedRegionC.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/proc_info.h>
#include <unistd.h>

// Sizes `fd` to `count` and fills it through a mapping, unmapped before return.
static int fill(int fd, const void *bytes, size_t count) {
  if (ftruncate(fd, (off_t)count) != 0) return -1;
  void *mapping = mmap(NULL, count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (mapping == MAP_FAILED) return -1;
  memcpy(mapping, bytes, count);
  munmap(mapping, count);
  return 0;
}

int cmux_shared_region_create(const void *bytes, size_t count) {
  static atomic_uint serial = 0;
  if (bytes == NULL || count == 0) {
    errno = EINVAL;
    return -1;
  }
  // PSHMNAMLEN is 31: "/cmux-sr-", a pid and a serial fit.
  for (int attempt = 0; attempt < 8; ++attempt) {
    char name[32];
    snprintf(name, sizeof name, "/cmux-sr-%d-%u", (int)getpid(), atomic_fetch_add(&serial, 1u));
    const int writable = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (writable < 0) {
      if (errno == EEXIST) continue;
      return -1;
    }
    const int readable = shm_open(name, O_RDONLY, 0);
    const int saved = errno;
    shm_unlink(name);
    if (readable < 0) {
      close(writable);
      errno = saved;
      return -1;
    }
    const int filled = fill(writable, bytes, count);
    close(writable);
    if (filled != 0 || fcntl(readable, F_SETFD, FD_CLOEXEC) != 0) {
      close(readable);
      return -1;
    }
    return readable;
  }
  errno = EEXIST;
  return -1;
}

int cmux_shared_region_is_sealed(int fd) {
  const int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || (flags & O_ACCMODE) != O_RDONLY) return 0;
  struct pshm_fdinfo info;
  return proc_pidfdinfo(getpid(), fd, PROC_PIDFDPSHMINFO, &info, (int)sizeof info) == (int)sizeof info;
}
