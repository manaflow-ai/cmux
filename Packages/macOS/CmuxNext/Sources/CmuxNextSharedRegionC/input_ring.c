#include "CmuxNextSharedRegionC.h"

#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

int cmux_input_ring_region_create(size_t count) {
  static atomic_uint serial = 0;
  if (count == 0) {
    errno = EINVAL;
    return -1;
  }
  // PSHMNAMLEN is 31: "/cmux-ir-", a pid and a serial fit.
  for (int attempt = 0; attempt < 8; ++attempt) {
    char name[32];
    snprintf(name, sizeof name, "/cmux-ir-%d-%u", (int)getpid(), atomic_fetch_add(&serial, 1u));
    const int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
      if (errno == EEXIST) continue;
      return -1;
    }
    shm_unlink(name);
    if (ftruncate(fd, (off_t)count) != 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
      const int saved = errno;
      close(fd);
      errno = saved;
      return -1;
    }
    return fd;
  }
  errno = EEXIST;
  return -1;
}

unsigned int cmux_input_ring_doorbell_look_up(const char *name) {
  mach_port_t port = MACH_PORT_NULL;
  if (name == NULL || bootstrap_look_up(bootstrap_port, name, &port) != KERN_SUCCESS) return MACH_PORT_NULL;
  return port;
}

// The same send as RingPort in chromium_host_input_ring.h.
int cmux_input_ring_doorbell_ring(unsigned int port) {
  mach_msg_empty_send_t message = {0};
  message.header.msgh_bits = MACH_MSGH_BITS_REMOTE(MACH_MSG_TYPE_COPY_SEND);
  message.header.msgh_size = sizeof message;
  message.header.msgh_remote_port = port;
  const kern_return_t result =
      mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
  return result == MACH_MSG_SUCCESS || result == MACH_SEND_TIMED_OUT;
}

void cmux_input_ring_doorbell_release(unsigned int port) {
  if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
}
