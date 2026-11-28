
/*--------------------------------------------------------------------*/
/*--- FreeBSD-specific kernel interface.             vki-freebsd.h ---*/
/*--------------------------------------------------------------------*/

/*
   This file is part of Valgrind, a dynamic binary instrumentation
   framework.

   Copyright (C) 2000-2005 Julian Seward
      jseward@acm.org
   Copyright (C) 2018-2021 Paul Floyd
      pjfloyd@wanadoo.fr

   This program is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License as
   published by the Free Software Foundation; either version 2 of the
   License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.

   The GNU General Public License is contained in the file COPYING.
*/

/* This file defines types and constants for the kernel interface, and to
   make that clear everything is prefixed VKI_/vki_.

   All code is copied verbatim from kernel source files, except that:
   - VKI_/vki_ prefixes are added
   - some extra explanatory comments are included;  they are all within
     "[[ ]]"
   - for some types, we only care about the size;  for a few of them (big
     ones that are painful to fully drag in here), a VKI_SIZEOF_* constant
     is used.

   The files the code is taken from is indicated.
*/

#ifndef VKI_FREEBSD_H
#define VKI_FREEBSD_H

//----------------------------------------------------------------------
// Arch-specific POSIX types
//----------------------------------------------------------------------

#if defined(VGA_x86)
#  include "vki-machine-types-x86-freebsd.h"
#elif defined(VGA_amd64)
#  include "vki-machine-types-amd64-freebsd.h"
#else
#  error Unknown platform
#endif

#include <sys/fcntl.h>
#include <sys/param.h>


//----------------------------------------------------------------------
// From sys/select.h
//----------------------------------------------------------------------

typedef unsigned long __vki_fd_mask;

#undef __VKI_NFDBITS
#define __VKI_NFDBITS   (8 * sizeof(__vki_fd_mask))

#undef __VKI_FD_SETSIZE
#define __VKI_FD_SETSIZE   1024U

#undef __VKI_FDSET_LONGS
#define __VKI_FDSET_LONGS  (__VKI_FD_SETSIZE/__VKI_NFDBITS)

#undef __VKI_FDELT
#define  __VKI_FDELT(d) ((d) / __VKI_NFDBITS)

#undef __VKI_FDMASK
#define  __VKI_FDMASK(d)   (1UL << ((d) % __VKI_NFDBITS))

typedef struct {
   unsigned long fds_bits [__VKI_FDSET_LONGS];
} __vki_fd_set;

//----------------------------------------------------------------------
// sys/_types.h
//----------------------------------------------------------------------
/* MD QQQ 32 on 64 */
typedef  long     __vki_key_t;
typedef  long     __vki_suseconds_t;
typedef  struct __timer *__vki_timer_t;
typedef  struct __mq *__vki_mqd_t;

/* MI */
typedef  vki_uint32_t   __vki_blksize_t;
typedef  vki_int64_t __vki_blkcnt_t;
typedef  vki_int32_t __vki_clockid_t;
typedef  vki_int32_t __vki_ct_rune_t;
typedef  vki_uint32_t   __vki_fflags_t;
typedef  vki_uint64_t   __vki_fsblkcnt_t;
typedef  vki_uint64_t   __vki_fsfilcnt_t;
typedef  vki_uint32_t   __vki_gid_t;
typedef  vki_int64_t __vki_id_t;
typedef  vki_uint64_t   __vki_ino_t;
typedef  vki_int32_t __vki_lwpid_t;
typedef  vki_uint16_t   __vki_mode_t;
typedef  vki_uint64_t   __vki_nlink_t;
typedef  vki_int64_t __vki_off_t;
typedef  vki_int32_t __vki_pid_t;
typedef  vki_int64_t __vki_rlim_t;
typedef  vki_uint8_t __vki_sa_family_t;
typedef  vki_uint32_t   __vki_socklen_t;
typedef  vki_uint32_t   __vki_uid_t;
typedef  vki_int32_t __vki_useconds_t;
typedef  __vki_ct_rune_t   __vki_rune_t;
typedef  __vki_ct_rune_t   __vki_wchar_t;
typedef  __vki_ct_rune_t   __vki_wint_t;
typedef  vki_uint64_t   __vki_dev_t;
typedef  vki_uint32_t   __vki_fixpt_t;


//----------------------------------------------------------------------
// sys/types.h
//----------------------------------------------------------------------

typedef  vki_uint8_t    vki_u_int8_t;
typedef  vki_uint16_t      vki_u_int16_t;
typedef  vki_uint32_t      vki_u_int32_t;
typedef  vki_uint64_t      vki_u_int64_t;

typedef  vki_uint64_t      vki_u_quad_t;
typedef  vki_int64_t    vki_quad_t;
typedef  __vki_caddr_t     vki_caddr_t;
typedef __const __vki_caddr_t vki_c_caddr_t;
typedef __volatile __vki_caddr_t vki_v_caddr_t;

typedef __vki_blksize_t    vki_blksize_t;
typedef __vki_blkcnt_t     vki_blkcnt_t;
typedef __vki_clock_t      vki_clock_t;
typedef __vki_clockid_t    vki_clockid_t;
typedef __vki_dev_t     vki_dev_t;
typedef __vki_fflags_t     vki_fflags_t;
typedef __vki_fixpt_t      vki_fixpt_t;
typedef __vki_fsblkcnt_t   vki_fsblkcnt_t;
typedef __vki_fsfilcnt_t   vki_fsfilcnt_t;
typedef __vki_gid_t     vki_gid_t;
typedef vki_uint32_t    vki_in_addr_t;
typedef vki_uint16_t    vki_in_port_t;
typedef __vki_id_t      vki_id_t;
typedef __vki_ino_t     vki_ino_t;
typedef __vki_key_t     vki_key_t;
typedef __vki_lwpid_t      vki_lwpid_t;
typedef __vki_mode_t    vki_mode_t;
typedef __vki_nlink_t      vki_nlink_t;
typedef __vki_off_t     vki_off_t;
typedef __vki_pid_t     vki_pid_t;
typedef __vki_register_t   vki_register_t;
typedef __vki_rlim_t    vki_rlim_t;
typedef __vki_segsz_t      vki_segsz_t;
typedef __vki_size_t    vki_size_t;
typedef __vki_ssize_t      vki_ssize_t;
typedef __vki_suseconds_t  vki_suseconds_t;
typedef __vki_time_t    vki_time_t;
typedef __vki_timer_t      vki_timer_t;
typedef __vki_mqd_t     vki_mqd_t;
typedef __vki_u_register_t vki_u_register_t;
typedef __vki_uid_t     vki_uid_t;
typedef __vki_useconds_t   vki_useconds_t;
typedef int             vki_cpuwhich_t;
typedef int             vki_cpulevel_t;
typedef int             vki_cpusetid_t;


typedef __vki_vm_offset_t  vki_vm_offset_t;
typedef __vki_vm_ooffset_t vki_vm_ooffset_t;
typedef __vki_vm_paddr_t   vki_vm_paddr_t;
typedef __vki_vm_pindex_t  vki_vm_pindex_t;
typedef __vki_vm_size_t    vki_vm_size_t;

//----------------------------------------------------------------------
// sys/select.h
//----------------------------------------------------------------------

typedef __vki_fd_set    vki_fd_set;

//----------------------------------------------------------------------
// Now the rest of the arch-specific stuff
//----------------------------------------------------------------------

#if defined(VGA_x86)
#  include "vki-x86-freebsd.h"
#elif defined(VGA_amd64)
#  include "vki-amd64-freebsd.h"
#else
#  error Unknown platform
#endif

//----------------------------------------------------------------------
// freebsd version hacks
//----------------------------------------------------------------------
#ifndef ELFMAG
#define ELFMAG "\177ELF"   /* magic string */
#endif
#ifndef SELFMAG
#define SELFMAG   4     /* magic string size */
#endif

// see http://bugs.freebsd.org/bugzilla/show_bug.cgi?id=239669
#if !defined(ELF_NOTE_GNU)
#define ELF_NOTE_GNU "GNU"
#endif


#define VKI_ELF_NOTE_ROUNDSIZE 4


//----------------------------------------------------------------------
// From sys/syslimits.h
//----------------------------------------------------------------------

#define VKI_PATH_MAX       1024


//----------------------------------------------------------------------
// From sys/timespec.h
//----------------------------------------------------------------------

struct vki_timespec {
   vki_time_t  tv_sec;     /* seconds */
   long     tv_nsec; /* nanoseconds */
};

struct  vki_itimerspec {
   struct  vki_timespec it_interval;    /* timer period */
   struct  vki_timespec it_value;       /* timer expiration */
};

//----------------------------------------------------------------------
// From sys/_time.h
//----------------------------------------------------------------------

struct vki_timeval {
   vki_time_t  tv_sec;     /* seconds */
   vki_suseconds_t   tv_usec; /* microseconds */
};

//----------------------------------------------------------------------
// From sys/time.h
//----------------------------------------------------------------------

#define VKI_CLOCK_REALTIME            0
#define VKI_CLOCK_MONOTONIC           1
#define VKI_CLOCK_PROCESS_CPUTIME_ID  2
#define VKI_CLOCK_THREAD_CPUTIME_ID   3

struct vki_timezone {
   int   tz_minuteswest;   /* minutes west of Greenwich */
   int   tz_dsttime; /* type of dst correction */
};

struct   vki_itimerval {
   struct   vki_timeval it_interval;   /* timer interval */
   struct   vki_timeval it_value;   /* current value */
};

//----------------------------------------------------------------------
// From sys/timex.h
//----------------------------------------------------------------------

struct vki_ntptimeval {
   struct vki_timespec time;
   long maxerror;
   long esterror;
   long tai;
   int time_state;
};

struct vki_timex {
   unsigned int modes;  /* mode selector */
   long offset;      /* time offset (usec) */
   long freq;     /* frequency offset (scaled ppm) */
   long maxerror;    /* maximum error (usec) */
   long esterror;    /* estimated error (usec) */
   int status;    /* clock command/status */
   long constant;    /* pll time constant */
   long precision;      /* clock precision (usec) (read only) */
   long tolerance;      /* clock frequency tolerance (ppm)
             * (read only)
             */
   long ppsfreq;           /* pps frequency (scaled ppm) (ro) */
   long jitter;            /* pps jitter (us) (ro) */
   int shift;              /* interval duration (s) (shift) (ro) */
   long stabil;            /* pps stability (scaled ppm) (ro) */
   long jitcnt;            /* jitter limit exceeded (ro) */
   long calcnt;            /* calibration intervals (ro) */
   long errcnt;            /* calibration errors (ro) */
   long stbcnt;            /* stability limit exceeded (ro) */
};

#define MOD_OFFSET      0x0001   /* time offset */
#define MOD_FREQUENCY      0x0002   /* frequency offset */
#define MOD_MAXERROR    0x0004   /* maximum time error */
#define MOD_ESTERROR    0x0008   /* estimated time error */
#define MOD_STATUS      0x0010   /* clock status */
#define MOD_TIMECONST      0x0020   /* pll time constant */
#define MOD_PPSMAX      0x0040
#define MOD_TAI         0x0080
#define MOD_MICRO    0x1000
#define MOD_NANO     0x2000
#define MOD_CLKB     0x4000
#define MOD_CLKA     0x8000

//----------------------------------------------------------------------
// From sys/times.h
//----------------------------------------------------------------------

struct vki_tms {
   vki_clock_t tms_utime;
   vki_clock_t tms_stime;
   vki_clock_t tms_cutime;
   vki_clock_t tms_cstime;
};

//----------------------------------------------------------------------
// From sys/stat.h
//----------------------------------------------------------------------

/* QQQ 4.x stat layout */
struct vki_freebsd11_stat {
   vki_uint32_t   st_dev;
   vki_uint32_t   st_ino;
   vki_mode_t  st_mode;
   vki_uint16_t st_nlink;
   vki_uid_t   st_uid;
   vki_gid_t   st_gid;
   vki_uint32_t   st_rdev;
#if 0
   struct vki_timespec  st_atimespec;
   struct vki_timespec  st_mtimespec;
   struct vki_timespec  st_ctimespec;
#else
   vki_time_t  st_atime;
   long     st_atime_nsec;
   vki_time_t  st_mtime;
   long     st_mtime_nsec;
   vki_time_t  st_ctime;
   long     st_ctime_nsec;
#endif
   vki_off_t   st_size;
   vki_blkcnt_t   st_blocks;
   vki_blksize_t  st_blksize;
   vki_fflags_t   st_flags;
   vki_uint32_t   st_gen;
   vki_int32_t st_lspare;
   struct vki_timespec  st_birthtimespec;
unsigned int :
   (8 / 2) * (16 - (int)sizeof(struct vki_timespec));
unsigned int :
   (8 / 2) * (16 - (int)sizeof(struct vki_timespec));
};

#if defined(VGP_x86_freebsd)
#define  VKI_STAT_TIME_T_EXT  1
#endif

/*
 * FreeBSD 12 has two versions of the stat struct
 * freebsd11_stat, which is the same as vki_stat above
 * and just stat, which is the same as vki_stat below
 * Since vki_stat is used by other OSes, it's best not to
 * use the same naming
 */

struct vki_stat {
   vki_dev_t     st_dev;
   vki_ino_t     st_ino;
   vki_nlink_t   st_nlink;
   vki_mode_t   st_mode;
   vki_int16_t st_padding0;
   vki_uid_t    st_uid;
   vki_gid_t    st_gid;
   vki_int32_t st_padding1;
   vki_dev_t     st_rdev;
#ifdef   VKI_STAT_TIME_T_EXT
   vki_int32_t st_atim_ext;
#endif
   //struct   vki_timespec st_atim;
   vki_time_t st_atime;
   long    st_atime_nsec;
#ifdef   VKI_STAT_TIME_T_EXT
   vki_int32_t st_mtim_ext;
#endif
   //struct   vki_timespec st_mtim;
   vki_time_t st_mtime;
   long    st_mtime_nsec;
#ifdef   VKI_STAT_TIME_T_EXT
   vki_int32_t st_ctim_ext;
#endif
   //struct   vki_timespec st_ctim;
   vki_time_t st_ctime;
   long    st_ctime_nsec;
#ifdef   VKI_STAT_TIME_T_EXT
   vki_int32_t st_btim_ext;
#endif
   //struct   vki_timespec st_birthtim;
   vki_time_t st_btime;
   long    st_btime_nsec;
   vki_off_t    st_size;
   vki_blkcnt_t st_blocks;
   vki_blksize_t st_blksize;
   vki_fflags_t  st_flags;
   vki_uint64_t st_gen;
   vki_uint64_t st_spare[10];
};



//----------------------------------------------------------------------
// From linux-2.6.8.1/include/linux/sched.h
//----------------------------------------------------------------------

struct vki_sched_param {
   int sched_priority;
};

//----------------------------------------------------------------------
// From sys/signal.h
//----------------------------------------------------------------------

#define  VKI_SIG_BLOCK  1  /*  block specified signal set */
#define  VKI_SIG_UNBLOCK   2  /*  unblock specified signal set */
#define  VKI_SIG_SETMASK   3  /*  set specified signal set */

#define  VKI_SIG_DFL ((__vki_sighandler_t)0)
#define  VKI_SIG_IGN ((__vki_sighandler_t)1)
#define  VKI_SIG_ERR ((__vki_sighandler_t)-1)

typedef void __vki_signalfn_t(int);
typedef __vki_signalfn_t *__vki_sighandler_t;

#define  VKI_SIGHUP     1
#define  VKI_SIGINT     2
#define  VKI_SIGQUIT    3
#define  VKI_SIGILL     4
#define  VKI_SIGTRAP    5
#define  VKI_SIGABRT    6
#define  VKI_SIGEMT     7
#define  VKI_SIGFPE     8
#define  VKI_SIGKILL    9
#define  VKI_SIGBUS     10
#define  VKI_SIGSEGV    11
#define  VKI_SIGSYS     12
#define  VKI_SIGPIPE    13
#define  VKI_SIGALRM    14
#define  VKI_SIGTERM    15
#define  VKI_SIGURG     16
#define  VKI_SIGSTOP    17
#define  VKI_SIGTSTP    18
#define  VKI_SIGCONT    19
#define  VKI_SIGCHLD    20
#define  VKI_SIGTTIN    21
#define  VKI_SIGTTOU    22
#define  VKI_SIGIO      23
#define  VKI_SIGXCPU    24
#define  VKI_SIGXFSZ    25
#define  VKI_SIGVTALRM  26
#define  VKI_SIGPROF    27
#define  VKI_SIGWINCH   28
#define  VKI_SIGINFO    29
#define  VKI_SIGUSR1    30
#define  VKI_SIGUSR2    31
#define  VKI_SIGTHR     32
#define  VKI_SIGLIBRT   33

#define  VKI_SIGRTMIN      65
#define  VKI_SIGRTMAX      126

#define  VKI_SA_ONSTACK    0x0001
#define  VKI_SA_RESTART    0x0002
#define  VKI_SA_RESETHAND  0x0004
#define  VKI_SA_NOCLDSTOP  0x0008
#define  VKI_SA_NODEFER    0x0010
#define  VKI_SA_NOCLDWAIT  0x0020
#define  VKI_SA_SIGINFO    0x0040
#define VKI_SA_RESTORER         0 /* FreeBSD doesn't have this */

#define  VKI_SS_ONSTACK    0x0001
#define  VKI_SS_DISABLE    0x0004

#define  VKI_SA_ONESHOT    VKI_SA_RESETHAND
#define  VKI_SA_NOMASK     VKI_SA_NODEFER

struct vki_sigaction {
   __vki_sighandler_t ksa_handler;
   int      sa_flags;
   vki_sigset_t   sa_mask;
};

typedef struct vki_sigaltstack {
   void     *ss_sp;
   vki_size_t  ss_size;
   int      ss_flags;
} vki_stack_t;

typedef union vki_sigval {
   int sival_int;
   void *sival_ptr;
} vki_sigval_t;

typedef struct vki_siginfo {
   int si_signo;
   int si_errno;
   int si_code;
   vki_pid_t si_pid;
   vki_uid_t si_uid;
   int si_status;
   void *si_addr;
   vki_sigval_t si_value;
// 666: not valid. switch to above def
#ifdef si_band
#undef si_band
#endif
   long si_band;
   int __spare__[7];
} vki_siginfo_t;

/*
 * si_code values
 */
#define VKI_SI_USER  0x10001     /* sent by kill, sigsend, raise */
#define VKI_SI_QUEUE 0x10002
#define VKI_SI_TIMER 0x10003
#define VKI_SI_ASYNCIO  0x10004
#define VKI_SI_MESGQ 0x10005
#define VKI_SI_KERNEL   0x10006
#define VKI_SI_LWP      0x10007
/*
 * SIGILL si_codes
 */
#define VKI_ILL_ILLOPC  1  /* illegal opcode */
#define VKI_ILL_ILLOPN  2  /* illegal operand */
#define VKI_ILL_ILLADR  3  /* illegal addressing mode */
#define VKI_ILL_ILLTRP  4  /* illegal trap */
#define VKI_ILL_PRVOPC  5  /* privileged opcode */
#define VKI_ILL_PRVREG  6  /* privileged register */
#define VKI_ILL_COPROC  7  /* coprocessor error */
#define VKI_ILL_BADSTK  8  /* internal stack error */

/*
 * SIGFPE si_codes
 */
#define VKI_FPE_INTOVF  1  /* integer overflow */
#define VKI_FPE_INTDIV  2  /* integer divide by zero */
#define VKI_FPE_FLTDIV  3  /* floating point divide by zero */
#define VKI_FPE_FLTOVF  4  /* floating point overflow */
#define VKI_FPE_FLTUND  5  /* floating point underflow */
#define VKI_FPE_FLTRES  6  /* floating point inexact result */
#define VKI_FPE_FLTINV  7  /* floating point invalid operation */
#define VKI_FPE_FLTSUB  8  /* subscript out of range */

/*
 * SIGSEGV si_codes
 */
#define VKI_SEGV_MAPERR 1  /* address not mapped to object */
#define VKI_SEGV_ACCERR 2  /* invalid permissions for mapped object */
/* XXX i386 and amd64 specific */
#define  VKI_SEGV_PAGE_FAULT  12

/*
 * SIGBUS si_codes
 */
#define VKI_BUS_ADRALN  1  /* invalid address alignment */
#define VKI_BUS_ADRERR  2  /* non-existant physical address */
#define VKI_BUS_OBJERR  3  /* object specific hardware error */
#define VKI_BUS_OOMERR  100   /* Non-standard: No memory.  */

/*
 * SIGTRAP si_codes
 */
#define VKI_TRAP_BRKPT  1  /* process breakpoint */
#define VKI_TRAP_TRACE  2  /* process trace trap */
#define VKI_TRAP_DTRACE 3   /* DTrace induced trap.                 */
#define VKI_TRAP_CAP    4   /* Capabilities protective trap.        */

/*
 * SIGCHLD si_codes
 */
#define VKI_CLD_EXITED    1  /* child has exited */
#define VKI_CLD_KILLED    2  /* child was killed */
#define VKI_CLD_DUMPED    3  /* child terminated abnormally */
#define VKI_CLD_TRAPPED   4  /* traced child has trapped */
#define VKI_CLD_STOPPED   5  /* child has stopped */
#define VKI_CLD_CONTINUED 6  /* stopped child has continued */

#if 0 /* freebsd-6 */
typedef struct vki_sigevent {
   int sigev_notify;
   int sigev_signo;
   vki_sigval_t sigev_value;
   union {
      int _threadid;

      struct {
         void (*_function)(vki_sigval_t);
         void *_attribute; /* really pthread_attr_t */
      } _sigev_thread;
      long __spare__[8];
   } _sigev_un;
} vki_sigevent_t;
#endif

struct vki_sigevent {
   int     sigev_notify;           /* Notification type */
   union {
      int   __sigev_signo;  /* Signal number */
      int   __sigev_notify_kqueue;
   } __sigev_u;
   vki_sigval_t sigev_value;       /* Signal value */
};
#if 0
#define sigev_signo             __sigev_u.__sigev_signo
#define sigev_notify_kqueue     __sigev_u.__sigev_notify_kqueue
#endif

//----------------------------------------------------------------------
// From sys/_iovec.h
//----------------------------------------------------------------------

struct vki_iovec {
   void *iov_base;
   __vki_size_t iov_len;
};

//----------------------------------------------------------------------
// From sys/socket.h
//----------------------------------------------------------------------

typedef __vki_sa_family_t  vki_sa_family_t;
typedef __vki_socklen_t    vki_socklen_t;

struct vki_sockaddr {
   vki_uint8_t sa_len;
   vki_sa_family_t   sa_family;  /* address family, AF_xxx  */
   char     sa_data[14];   /* 14 bytes of protocol address  */
};

struct vki_msghdr {
   void  *  msg_name;   /* Socket name       */
   vki_socklen_t  msg_namelen;   /* Length of name    */
   struct vki_iovec *   msg_iov; /* Data blocks       */
   int      msg_iovlen; /* Number of blocks     */
   void  *  msg_control;   /* Per protocol magic (eg BSD file descriptor passing) */
   vki_socklen_t  msg_controllen;   /* Length of cmsg list */
   int      msg_flags;
};

struct vki_cmsghdr {
   vki_socklen_t  cmsg_len;   /* data byte count, including hdr */
   int    cmsg_level; /* originating protocol */
   int    cmsg_type;  /* protocol-specific type */
};

#define __VKI_CMSG_NXTHDR(ctl, len, cmsg) __vki_cmsg_nxthdr((ctl),(len),(cmsg))
#define VKI_CMSG_NXTHDR(mhdr, cmsg) vki_cmsg_nxthdr((mhdr), (cmsg))

#define VKI_CMSG_ALIGN(len) ( ((len)+sizeof(long)-1) & ~(sizeof(long)-1) )

#define VKI_CMSG_DATA(cmsg)   ((void *)((char *)(cmsg) + VKI_CMSG_ALIGN(sizeof(struct vki_cmsghdr))))

#define __VKI_CMSG_FIRSTHDR(ctl,len) ((len) >= sizeof(struct vki_cmsghdr) ? \
              (struct vki_cmsghdr *)(ctl) : \
              (struct vki_cmsghdr *)NULL)
#define VKI_CMSG_FIRSTHDR(msg)   __VKI_CMSG_FIRSTHDR((msg)->msg_control, (msg)->msg_controllen)

// [[Urgh, this is revolting...]
// QQQ check
static __inline struct vki_cmsghdr * __vki_cmsg_nxthdr(void *__ctl, vki_socklen_t __size,
      struct vki_cmsghdr *__cmsg)
{
   struct vki_cmsghdr * __ptr;

   __ptr = (struct vki_cmsghdr*)(((unsigned char *) __cmsg) +  VKI_CMSG_ALIGN(__cmsg->cmsg_len));
   if ((unsigned long)((char*)(__ptr+1) - (char *) __ctl) > __size)
      return (struct vki_cmsghdr *)0;

   return __ptr;
}

static __inline struct vki_cmsghdr * vki_cmsg_nxthdr (struct vki_msghdr *__msg, struct vki_cmsghdr *__cmsg)
{
   return __vki_cmsg_nxthdr(__msg->msg_control, __msg->msg_controllen, __cmsg);
}

#define  VKI_SCM_RIGHTS 0x01     /* rw: access rights (array of int) */

#define VKI_AF_UNIX  1  /* Unix domain sockets     */
#define VKI_AF_INET  2  /* Internet IP Protocol    */
#define VKI_AF_INET6 28 /* IP version 6         */

#define VKI_MSG_NOSIGNAL   0x20000  /* Do not generate SIGPIPE */

#define VKI_SOL_SOCKET  0xffff

#define VKI_SO_TYPE  0x1008

#define VKI_SOCK_STREAM 1

#include <netinet/tcp.h>

#define VKI_TCP_NODELAY  TCP_NODELAY

#include <netinet/in.h>

#define VKI_IPPROTO_TCP  IPPROTO_TCP

struct vki_sf_hdtr {
   struct iovec *headers;
   int hdr_cnt;
   struct iovec *trailers;
   int trl_cnt;
};


//----------------------------------------------------------------------
// From netinet/in.h
//----------------------------------------------------------------------

struct vki_in_addr {
   vki_in_addr_t  s_addr;
};

/* Structure describing an Internet (IP) socket address. */
#define __VKI_SOCK_SIZE__  16 /* sizeof(struct sockaddr) */
struct vki_sockaddr_in {
   vki_uint8_t     sin_len;
   vki_sa_family_t sin_family; /* Address family    */
   vki_in_port_t      sin_port;   /* Port number       */
   struct vki_in_addr sin_addr;   /* Internet address     */
   char         sin_zero[8];
};

//----------------------------------------------------------------------
// From netinet6/in6.h
//----------------------------------------------------------------------

struct vki_in6_addr {
   union {
      vki_uint8_t u6_addr8[16];
      vki_uint16_t   u6_addr16[8];
      vki_uint32_t   u6_addr32[4];
   } vki_in6_u;
#define vki_s6_addr     vki_in6_u.u6_addr8
#define vki_s6_addr16      vki_in6_u.u6_addr16
#define vki_s6_addr32      vki_in6_u.u6_addr32
};

struct vki_sockaddr_in6 {
   vki_uint8_t    sin6_len;
   vki_sa_family_t      sin6_family;    /* AF_INET6 */
   vki_uint16_t      sin6_port;      /* Transport layer port # */
   vki_uint32_t      sin6_flowinfo;  /* IPv6 flow information */
   struct vki_in6_addr  sin6_addr;      /* IPv6 address */
   vki_uint32_t      sin6_scope_id;  /* scope id (new in RFC2553) */
};

//----------------------------------------------------------------------
// From netinet/sctp_uio.h
//----------------------------------------------------------------------
#define VKI_SCTP_ALIGN_RESV_PAD 92

typedef vki_uint32_t vki_sctp_assoc_t;

struct vki_sctp_sndrcvinfo {
   vki_uint16_t sinfo_stream;
   vki_uint16_t sinfo_ssn;
   vki_uint16_t sinfo_flags;
   vki_uint32_t sinfo_ppid;
   vki_uint32_t sinfo_context;
   vki_uint32_t sinfo_timetolive;
   vki_uint32_t sinfo_tsn;
   vki_uint32_t sinfo_cumtsn;
   vki_sctp_assoc_t sinfo_assoc_id;
   vki_uint16_t sinfo_keynumber;
   vki_uint16_t sinfo_keynumber_valid;
   vki_uint8_t __reserve_pad[VKI_SCTP_ALIGN_RESV_PAD];
};

//----------------------------------------------------------------------
// From sys/un.h
//----------------------------------------------------------------------

#define VKI_UNIX_PATH_MAX  104   /* QQQ overridden by sun_len */

struct vki_sockaddr_un {
   unsigned char sun_len;
   vki_sa_family_t sun_family;   /* AF_UNIX */
   char sun_path[VKI_UNIX_PATH_MAX];   /* pathname */
};

//----------------------------------------------------------------------
// From aio.h
//----------------------------------------------------------------------

struct vki___aiocb_private {
   long    status;
   long    error;
   void    *kernelinfo;
};

typedef struct vki_aiocb {
   int     aio_fildes;
   vki_off_t   aio_offset;
   volatile void *aio_buf;
   vki_size_t  aio_nbytes;
   int     __spare__[2];
   void    *__spare2__;
   int     aio_lio_opcode;
   int     aio_reqprio;
   struct  vki___aiocb_private _aiocb_private;
   struct  vki_sigevent aio_sigevent;
} aiocb_t;

#define VKI_LIO_NOP                 0x0
#define VKI_LIO_WRITE               0x1
#define VKI_LIO_READ                0x2

#define VKI_LIO_NOWAIT              0x0
#define VKI_LIO_WAIT                0x1


#define VKI_LIO_NOWAIT 0x0

//----------------------------------------------------------------------
// From sys/mount.h
//----------------------------------------------------------------------

typedef struct vki_fsid {
   vki_int32_t val[2];
} vki_fsid_t;
#define VKI_OMFSNAMELEN 16
#define VKI_OMNAMELEN   (88 - 2 * sizeof(long))
#define VKI_MFSNAMELEN  16
#define VKI_FREEBSD11_MNAMELEN   88

struct vki_freebsd11_statfs {
   vki_uint32_t f_version;
   vki_uint32_t f_type;
   vki_uint64_t f_flags;
   vki_uint64_t f_bsize;
   vki_uint64_t f_iosize;
   vki_uint64_t f_blocks;
   vki_uint64_t f_bfree;
   vki_int64_t  f_bavail;
   vki_uint64_t f_files;
   vki_int64_t  f_ffree;
   vki_uint64_t f_syncwrites;
   vki_uint64_t f_asyncwrites;
   vki_uint64_t f_syncreads;
   vki_uint64_t f_asyncreads;
   vki_uint64_t f_spare[10];
   vki_uint32_t f_namemax;
   vki_uid_t     f_owner;
   vki_fsid_t    f_fsid;
   char      f_charspare[80];
   char      f_fstypename[VKI_OMFSNAMELEN];
   char      f_mntfromname[VKI_FREEBSD11_MNAMELEN];
   char      f_mntonname[VKI_FREEBSD11_MNAMELEN];
};


#define MAXFIDSZ        16

struct vki_fid {
   vki_uint16_t    fid_len;
   vki_uint16_t    fid_reserved;
   char            fid_data[MAXFIDSZ];
};

struct vki_fhandle {
   vki_fsid_t  fh_fsid;
   struct vki_fid fh_fid;
};


#define VKI_MNAMELEN        1024
struct vki_statfs {
   vki_uint32_t f_version;
   vki_uint32_t f_type;
   vki_uint64_t f_flags;
   vki_uint64_t f_bsize;
   vki_uint64_t f_iosize;
   vki_uint64_t f_blocks;
   vki_uint64_t f_bfree;
   vki_int64_t  f_bavail;
   vki_uint64_t f_files;
   vki_int64_t  f_ffree;
   vki_uint64_t f_syncwrites;
   vki_uint64_t f_asyncwrites;
   vki_uint64_t f_syncreads;
   vki_uint64_t f_asyncreads;
   vki_uint64_t f_spare[10];
   vki_uint32_t f_namemax;
   vki_uid_t     f_owner;
   vki_fsid_t    f_fsid;
   char      f_charspare[80];
   char      f_fstypename[VKI_MFSNAMELEN];
   char      f_mntfromname[VKI_MNAMELEN];
   char      f_mntonname[VKI_MNAMELEN];
};

typedef struct vki_fhandle  vki_fhandle_t;

//----------------------------------------------------------------------
// From sys/ttycom.h
//----------------------------------------------------------------------

struct vki_winsize {
   unsigned short ws_row;
   unsigned short ws_col;
   unsigned short ws_xpixel;
   unsigned short ws_ypixel;
};


//----------------------------------------------------------------------
// From sys/termios.h
//----------------------------------------------------------------------

typedef unsigned int    vki_tcflag_t;
typedef unsigned char   vki_cc_t;
typedef unsigned int    vki_speed_t;

#define VKI_NCCS 20
struct vki_termios {
   vki_tcflag_t c_iflag;      /* input mode flags */
   vki_tcflag_t c_oflag;      /* output mode flags */
   vki_tcflag_t c_cflag;      /* control mode flags */
   vki_tcflag_t c_lflag;      /* local mode flags */
   vki_cc_t c_cc[VKI_NCCS];   /* control characters */
   vki_speed_t c_ispeed;
   vki_speed_t c_ospeed;
};

//----------------------------------------------------------------------
// From sys/ioccom.h
//----------------------------------------------------------------------

/* QQQ keep linux's naming, but use our layout */

/*
 * We actually have a 16 bit "base" ioctl, which may or may not be decoded
 * into number/group
 */
#define _VKI_IOC_BASEBITS  16U
#define _VKI_IOC_NRBITS    8U  /* "num" on freebsd */
#define _VKI_IOC_TYPEBITS  8U  /* "group" on freebsd */

#define _VKI_IOC_SIZEBITS  13U
#define _VKI_IOC_DIRBITS   3U

#define _VKI_IOC_BASEMASK  ((1ul << _VKI_IOC_BASEBITS)-1)
#define _VKI_IOC_NRMASK    ((1ul << _VKI_IOC_NRBITS)-1)
#define _VKI_IOC_TYPEMASK  ((1ul << _VKI_IOC_TYPEBITS)-1)
#define _VKI_IOC_SIZEMASK  ((1ul << _VKI_IOC_SIZEBITS)-1)
#define _VKI_IOC_DIRMASK   ((1ul << _VKI_IOC_DIRBITS)-1)

#define  _VKI_IOC_BASESHIFT   0U
#define _VKI_IOC_NRSHIFT   0U
#define _VKI_IOC_TYPESHIFT (_VKI_IOC_NRSHIFT+_VKI_IOC_NRBITS)
#define _VKI_IOC_SIZESHIFT (_VKI_IOC_TYPESHIFT+_VKI_IOC_TYPEBITS)
#define _VKI_IOC_DIRSHIFT  (_VKI_IOC_SIZESHIFT+_VKI_IOC_SIZEBITS)

#define _VKI_IOC_NONE   1U /* "void" on freebsd, as a specific mode */
#define _VKI_IOC_READ   2U /* "out", copyout in reversed linux terminology */
#define _VKI_IOC_WRITE  4U /* "in", copyin in reversed linux terminology */
#define _VKI_IOC_RDWR   6U /* "inout", copyin and copyout */

#define _VKI_IOC(dir,type,nr,size) \
   (((dir)  << _VKI_IOC_DIRSHIFT) | \
    ((type) << _VKI_IOC_TYPESHIFT) | \
    ((nr)   << _VKI_IOC_NRSHIFT) | \
    ((size) << _VKI_IOC_SIZESHIFT))

/* provoke compile error for invalid uses of size argument */
extern unsigned int __vki_invalid_size_argument_for_IOC;
#define _VKI_IOC_TYPECHECK(t) \
   ((sizeof(t) == sizeof(t[1]) && \
     sizeof(t) < (1 << _VKI_IOC_SIZEBITS)) ? \
     sizeof(t) : __vki_invalid_size_argument_for_IOC)

/* used to create numbers */
#define _VKI_IO(type,nr)   _VKI_IOC(_VKI_IOC_NONE,(type),(nr),0)
#define _VKI_IOR(type,nr,size)   _VKI_IOC(_VKI_IOC_READ,(type),(nr),(_VKI_IOC_TYPECHECK(size)))
#define _VKI_IOW(type,nr,size)   _VKI_IOC(_VKI_IOC_WRITE,(type),(nr),(_VKI_IOC_TYPECHECK(size)))
#define _VKI_IOWR(type,nr,size)  _VKI_IOC(_VKI_IOC_READ|_VKI_IOC_WRITE,(type),(nr),(_VKI_IOC_TYPECHECK(size)))

/* used to decode ioctl numbers.. */
#define _VKI_IOC_DIR(nr)   (((nr) >> _VKI_IOC_DIRSHIFT) & _VKI_IOC_DIRMASK)
#define _VKI_IOC_TYPE(nr)  (((nr) >> _VKI_IOC_TYPESHIFT) & _VKI_IOC_TYPEMASK)
#define _VKI_IOC_NR(nr)    (((nr) >> _VKI_IOC_NRSHIFT) & _VKI_IOC_NRMASK)
#define _VKI_IOC_SIZE(nr)  (((nr) >> _VKI_IOC_SIZESHIFT) & _VKI_IOC_SIZEMASK)
#define _VKI_IOC_BASE(nr)  (((nr) >> _VKI_IOC_BASESHIFT) & _VKI_IOC_BASEMASK)

//----------------------------------------------------------------------
// From sys/random.h
//----------------------------------------------------------------------

#define VKI_GRND_NONBLOCK 0x1U

//----------------------------------------------------------------------
// From sys/termios.h
//----------------------------------------------------------------------

#if 0
#define VKI_TCGETS   0x5401
#define VKI_TCSETS   0x5402 /* Clashes with SNDCTL_TMR_START sound ioctl */
#define VKI_TCSETSW  0x5403
#define VKI_TCSETSF  0x5404
#define VKI_TCGETA   0x5405   y
#define VKI_TCSETA   0x5406   y
#define VKI_TCSETAW  0x5407   y
#define VKI_TCSETAF  0x5408   y
#define VKI_TCSBRK   0x5409
#define VKI_TCXONC   0x540A
#define VKI_TCFLSH   0x540B   y
#define VKI_TIOCSCTTY   0x540E
#define VKI_TIOCGPGRP   0x540F   y
#define VKI_TIOCSPGRP   0x5410   y
#define VKI_TIOCOUTQ 0x5411
#define VKI_TIOCGWINSZ  0x5413   y
#define VKI_TIOCSWINSZ  0x5414   y
#define VKI_TIOCMGET 0x5415   y
#define VKI_TIOCMBIS 0x5416   y
#define VKI_TIOCMBIC 0x5417   y
#define VKI_TIOCMSET 0x5418   y
#define VKI_FIONREAD 0x541B
#define VKI_TIOCLINUX   0x541C
#define VKI_FIONBIO  0x5421
#define VKI_TCSBRKP  0x5425   /* Needed for POSIX tcsendbreak() */
#define VKI_TIOCGPTN _VKI_IOR('T',0x30, unsigned int) /* Get Pty Number (of pty-mux device) */
#define VKI_TIOCSPTLCK  _VKI_IOW('T',0x31, int)  /* Lock/unlock Pty */

#define VKI_FIOASYNC 0x5452
#define VKI_TIOCSERGETLSR   0x5459 /* Get line status register */

#define VKI_TIOCGICOUNT 0x545D   /* read serial port inline interrupt counts */
#endif

#define  VKI_TIOCFLUSH  _VKI_IOW('t', 16, int);
#define  VKI_TIOCGETA   _VKI_IOR('t', 19, struct vki_termios)  /* get termios */
#define  VKI_TIOCSETA   _VKI_IOR('t', 20, struct vki_termios)  /* set termios */
#define  VKI_TIOCSETAW  _VKI_IOR('t', 21, struct vki_termios)  /* drain,set */
#define  VKI_TIOCSETAF  _VKI_IOR('t', 22, struct vki_termios)  /* flush,set */

#define  _VKI_TIOCPTMASTER  _VKI_IO('t', 28)    /* pts master validation */

#define VKI_TIOCSWINSZ  _VKI_IOW('t', 103, struct vki_winsize)  /* set window size */
#define VKI_TIOCGWINSZ  _VKI_IOR('t', 104, struct vki_winsize)  /* get window size */

#define VKI_TIOCMGET _VKI_IOR('t', 106, int) /* get all modem bits */
#define VKI_TIOCMBIC _VKI_IOW('t', 107, int) /* bic modem bits */
#define VKI_TIOCMBIS _VKI_IOW('t', 108, int) /* bis modem bits */
#define VKI_TIOCMSET _VKI_IOW('t', 109, int) /* set all modem bits */
#define  VKI_TIOCSTART  _VKI_IO('t', 110)    /* start output, like ^Q */
#define  VKI_TIOCSTOP   _VKI_IO('t', 111)    /* stop output, like ^S */
#define  VKI_TIOCPKT    _VKI_IOW('t', 112, int) /* pty: set/clear packet mode */

#define  VKI_TIOCSPGRP  _VKI_IOW('t', 118, int)    /* set pgrp */
#define  VKI_TIOCGPGRP  _VKI_IOR('t', 119, int)    /* get pgrp */
#define  VKI_TIOCCBRK   _VKI_IO('t', 122)
#define  VKI_TIOCSBRK   _VKI_IO('t', 123)


//----------------------------------------------------------------------
// From sys/filio.h
//----------------------------------------------------------------------

#define VKI_FIOCLEX  _VKI_IO('f', 1)      /* close on exec */
#define VKI_FIONCLEX _VKI_IO('f', 2)      /* no close on exec */
#define VKI_FIONREAD _VKI_IOR('f', 127, int)
#define VKI_FIONBIO  _VKI_IOW('f', 126, int)
#define VKI_FIOASYNC _VKI_IOW('f', 125, int)
#define VKI_FIOSETOWN   _VKI_IOW('f', 124, int)
#define VKI_FIOGETOWN   _VKI_IOW('f', 123, int)

// See syswrap-freebsd.c PRE/POST(sys_ioctl)
#if 0
//----------------------------------------------------------------------
// From net/if.h
//----------------------------------------------------------------------
#define  VKI_IFNAMSIZ   16

struct vki_ifmediareq {
   char    ifm_name[VKI_IFNAMSIZ];
   int     ifm_current;
   int     ifm_mask;
   int     ifm_status;
   int     ifm_active;
   int     ifm_count;
   int     *ifm_ulist;
};


//----------------------------------------------------------------------
// From sys/sockio.h
//----------------------------------------------------------------------
#define VKI_SIOCGIFMEDIA  _VKI_IOWR('i', 56, struct vki_ifmediareq)
#endif

//----------------------------------------------------------------------
// From sys/poll.h
//----------------------------------------------------------------------

#define VKI_POLLIN      0x0001

struct vki_pollfd {
   int fd;
   short events;
   short revents;
};

//----------------------------------------------------------------------
// From sys/event.h
//----------------------------------------------------------------------
struct vki_kevent_freebsd11 {
   vki_uintptr_t  ident;
   vki_int16_t    filter;
   vki_uint16_t   flags;
   vki_uint32_t   fflags;
   vki_intptr_t   data;
   void           *udata;
};

struct vki_kevent {
   vki_uintptr_t  ident;
   vki_int16_t    filter;
   vki_uint16_t   flags;
   vki_uint32_t   fflags;
   vki_int64_t    data;
   void           *udata;
   vki_uint64_t   ext[4];
};


// QQQ sort

//----------------------------------------------------------------------
// From sys/resource.h
//----------------------------------------------------------------------

#define VKI_RUSAGE_SELF     0
#define VKI_RUSAGE_CHILDREN -1
#define VKI_RUSAGE_THREAD   1

struct   vki_rusage {
   struct vki_timeval ru_utime;  /* user time used */
   struct vki_timeval ru_stime;  /* system time used */
   long  ru_maxrss;     /* maximum resident set size */
   long  ru_ixrss;      /* integral shared memory size */
   long  ru_idrss;      /* integral unshared data size */
   long  ru_isrss;      /* integral unshared stack size */
   long  ru_minflt;     /* page reclaims */
   long  ru_majflt;     /* page faults */
   long  ru_nswap;      /* swaps */
   long  ru_inblock;    /* block input operations */
   long  ru_oublock;    /* block output operations */
   long  ru_msgsnd;     /* messages sent */
   long  ru_msgrcv;     /* messages received */
   long  ru_nsignals;      /* signals received */
   long  ru_nvcsw;      /* voluntary context switches */
   long  ru_nivcsw;     /* involuntary " */
};

struct vki_rlimit {
   vki_rlim_t  rlim_cur;
   vki_rlim_t  rlim_max;
};

#define VKI_RLIMIT_DATA    2  /* max data size */
#define VKI_RLIMIT_STACK   3  /* max stack size */
#define VKI_RLIMIT_CORE    4  /* max core file size */
#define VKI_RLIMIT_NOFILE  8  /* max number of open files */

struct vki___wrusage {
   struct vki_rusage   wru_self;
   struct vki_rusage   wru_children;
};


//----------------------------------------------------------------------
// From sys/procfs.h
//----------------------------------------------------------------------

#define VKI_PRSTATUS_VERSION  1
struct vki_elf_prstatus {
   int      pr_version; /* version of struct - PRSTATUS_VERSION */
   vki_size_t  pr_statussz;
   vki_size_t  pr_gregsetsz;
   vki_size_t  pr_fpregsetsz;
   int      pr_osreldate;
   int      pr_cursig;  /* Current signal */
   vki_pid_t   pr_pid;
   vki_elf_gregset_t pr_reg;  /* GP registers */
};

#define VKI_ELF_PRARGSZ (80)  /* Number of chars for args */
#define VKI_MAXCOMLEN   (16)

#define  VKI_PRPSINFO_VERSION 1
struct vki_elf_prpsinfo {
   int   pr_version; /* version of struct - PRPSINFO_VERSION */
   vki_size_t  pr_psinfosz;
   char  pr_fname[VKI_MAXCOMLEN+1];    /* filename of executable */
   char  pr_psargs[VKI_ELF_PRARGSZ];   /* initial part of arg list */
};

//----------------------------------------------------------------------
// From posix4/mqueue.h
//----------------------------------------------------------------------

struct vki_mq_attr {
   long  mq_flags;   /* message queue flags        */
   long  mq_maxmsg;  /* maximum number of messages    */
   long  mq_msgsize; /* maximum message size       */
   long  mq_curmsgs; /* number of messages currently queued */
};

//----------------------------------------------------------------------
// From sys/ucontext.h
//----------------------------------------------------------------------

#define  VKI_UCF_SWAPPED   1

struct vki_ucontext {
   vki_sigset_t      uc_sigmask;
   struct vki_mcontext  uc_mcontext;
   struct vki_ucontext  *uc_link;
   vki_stack_t    uc_stack;
   int         uc_flags;
   unsigned int      __spare__[4];
};

//----------------------------------------------------------------------
// From sys/utsname.h
//----------------------------------------------------------------------

#define VKI_SYS_NMLN        32

struct vki_utsname {
   char    sysname[VKI_SYS_NMLN];      /* Name of this OS. */
   char    nodename[VKI_SYS_NMLN];     /* Name of this network node. */
   char    release[VKI_SYS_NMLN];      /* Release level. */
   char    version[VKI_SYS_NMLN];      /* Version level. */
   char    machine[VKI_SYS_NMLN];      /* Hardware type. */
};

#define VKI_IPC_CREAT  00001000   /* create if key is nonexistent */
#define VKI_IPC_EXCL   00002000   /* fail if key exists */
#define VKI_IPC_NOWAIT 00004000   /* return error on wait */

#define VKI_IPC_RMID 0     /* remove resource */
#define VKI_IPC_SET  1     /* set ipc_perm options */
#define VKI_IPC_STAT 2     /* get ipc_perm options */
#define VKI_IPC_INFO 3     /* see ipcs */

//----------------------------------------------------------------------
// From sys/ipc.h
//----------------------------------------------------------------------

struct vki_ipc_perm_old {
   unsigned short cuid;
   unsigned short cgid;
   unsigned short uid;
   unsigned short gid;
   unsigned short mode;
   unsigned short seq;
   vki_key_t   key;
};

struct vki_ipc_perm {
   vki_uid_t   cuid;
   vki_gid_t   cgid;
   vki_uid_t   uid;
   vki_gid_t   gid;
   vki_mode_t  mode;
   unsigned short seq;
   vki_key_t   key;
};

//----------------------------------------------------------------------
// From sys/sem.h
//----------------------------------------------------------------------

#define VKI_GETALL  6       /* get all semval's */
#define VKI_SETVAL  8       /* set semval */
#define VKI_SETALL  9       /* set all semval's */
#define VKI_SEM_STAT 10
#define VKI_SEM_INFO 11

struct vki_semid_ds_old {
   struct vki_ipc_perm_old sem_perm;
   struct sem      *__sem_base;
   unsigned short  sem_nsems;
   vki_time_t      sem_otime;
   long            sem_pad1;
   vki_time_t      sem_ctime;
   long            sem_pad2;
   long            sem_pad3[4];
};


/* Obsolete, used only for backwards compatibility and libc5 compiles */
struct vki_semid_ds {
   struct vki_ipc_perm  sem_perm;      /* permissions .. see ipc.h */
   // [[Use void* to avoid excess header copying]]
   void/*struct sem  */*sem_base;      /* ptr to first semaphore in array */
   unsigned short    sem_nsems;     /* no. of semaphores in array */
   vki_time_t     sem_otime;     /* last semop time */
   vki_time_t     sem_ctime;     /* last change time */
};

struct vki_sembuf {
   vki_uint16_t   sem_num; /* semaphore index in array */
   vki_int16_t sem_op;     /* semaphore operation */
   vki_int16_t sem_flg; /* operation flags */
};

union vki_semun {
   int val;       /* value for SETVAL */
   struct vki_semid_ds *buf;  /* buffer for IPC_STAT & IPC_SET */
   vki_uint16_t *array; /* array for GETALL & SETALL */
};


//----------------------------------------------------------------------
// From sys/errno.h
//----------------------------------------------------------------------

#define VKI_ERESTART -1
#define VKI_EPERM           1               /* Operation not permitted */
#define VKI_ENOENT          2               /* No such file or directory */
#define VKI_ESRCH           3               /* No such process */
#define VKI_EINTR           4               /* Interrupted system call */
#define VKI_EIO             5               /* Input/output error */
#define VKI_ENXIO           6               /* Device not configured */
#define VKI_E2BIG           7               /* Argument list too long */
#define VKI_ENOEXEC         8               /* Exec format error */
#define VKI_EBADF           9               /* Bad file descriptor */
#define VKI_ECHILD          10              /* No child processes */
#define VKI_EDEADLK         11              /* Resource deadlock avoided */
#define VKI_ENOMEM          12              /* Cannot allocate memory */
#define VKI_EACCES          13              /* Permission denied */
#define VKI_EFAULT          14              /* Bad address */
#define VKI_ENOTBLK         15              /* Block device required */
#define VKI_EBUSY           16              /* Device busy */
#define VKI_EEXIST          17              /* File exists */
#define VKI_EXDEV           18              /* Cross-device link */
#define VKI_ENODEV          19              /* Operation not supported by device */
#define VKI_ENOTDIR         20              /* Not a directory */
#define VKI_EISDIR          21              /* Is a directory */
#define VKI_EINVAL          22              /* Invalid argument */
#define VKI_ENFILE          23              /* Too many open files in system */
#define VKI_EMFILE          24              /* Too many open files */
#define VKI_ENOTTY          25              /* Inappropriate ioctl for device */
#define VKI_ETXTBSY         26              /* Text file busy */
#define VKI_EFBIG           27              /* File too large */
#define VKI_ENOSPC          28              /* No space left on device */
#define VKI_ESPIPE          29              /* Illegal seek */
#define VKI_EROFS           30              /* Read-only filesystem */
#define VKI_EMLINK          31              /* Too many links */
#define VKI_EPIPE           32              /* Broken pipe */
#define VKI_EDOM            33              /* Numerical argument out of domain */
#define VKI_ERANGE          34              /* Result too large */
#define VKI_EAGAIN          35              /* Resource temporarily unavailable */
#define VKI_EWOULDBLOCK     VKI_EAGAIN          /* Operation would block */
#define VKI_EINPROGRESS     36              /* Operation now in progress */
#define VKI_EALREADY        37              /* Operation already in progress */
#define VKI_ENOTSOCK        38              /* Socket operation on non-socket */
#define VKI_EDESTADDRREQ    39              /* Destination address required */
#define VKI_EMSGSIZE        40              /* Message too long */
#define VKI_EPROTOTYPE      41              /* Protocol wrong type for socket */
#define VKI_ENOPROTOOPT     42              /* Protocol not available */
#define VKI_EPROTONOSUPPORT 43              /* Protocol not supported */
#define VKI_ESOCKTNOSUPPORT 44              /* Socket type not supported */
#define VKI_EOPNOTSUPP      45              /* Operation not supported */
#define VKI_ENOTSUP         VKI_EOPNOTSUPP      /* Operation not supported */
#define VKI_EPFNOSUPPORT    46              /* Protocol family not supported */
#define VKI_EAFNOSUPPORT    47              /* Address family not supported by protocol family */
#define VKI_EADDRINUSE      48              /* Address already in use */
#define VKI_EADDRNOTAVAIL   49
#define VKI_ENETDOWN        50              /* Network is down */
#define VKI_ENETUNREACH     51              /* Network is unreachable */
#define VKI_ENETRESET       52              /* Network dropped connection on reset */
#define VKI_ECONNABORTED    53              /* Software caused connection abort */
#define VKI_ECONNRESET      54              /* Connection reset by peer */
#define VKI_ENOBUFS         55              /* No buffer space available */
#define VKI_EISCONN         56              /* Socket is already connected */
#define VKI_ENOTCONN        57              /* Socket is not connected */
#define VKI_ESHUTDOWN       58              /* Can't send after socket shutdown */
#define VKI_ETOOMANYREFS    59              /* Too many references: can't splice */
#define VKI_ETIMEDOUT       60              /* Operation timed out */
#define VKI_ECONNREFUSED    61              /* Connection refused */
#define VKI_ELOOP           62              /* Too many levels of symbolic links */
#define VKI_ENAMETOOLONG    63              /* File name too long */
#define VKI_EHOSTDOWN       64              /* Host is down */
#define VKI_EHOSTUNREACH    65              /* No route to host */
#define VKI_ENOTEMPTY       66              /* Directory not empty */
#define VKI_EPROCLIM        67              /* Too many processes */
#define VKI_EUSERS          68              /* Too many users */
#define VKI_EDQUOT          69              /* Disc quota exceeded */
#define VKI_ESTALE          70              /* Stale NFS file handle */
#define VKI_EREMOTE         71              /* Too many levels of remote in path */
#define VKI_EBADRPC         72              /* RPC struct is bad */
#define VKI_ERPCMISMATCH    73              /* RPC version wrong */
#define VKI_EPROGUNAVAIL    74              /* RPC prog. not avail */
#define VKI_EPROGMISMATCH   75              /* Program version wrong */
#define VKI_EPROCUNAVAIL    76              /* Bad procedure for program */
#define VKI_ENOLCK          77              /* No locks available */
#define VKI_ENOSYS          78              /* Function not implemented */
#define VKI_EFTYPE          79              /* Inappropriate file type or format */
#define VKI_EAUTH           80              /* Authentication error */
#define VKI_ENEEDAUTH       81              /* Need authenticator */
#define VKI_EIDRM           82              /* Identifier removed */
#define VKI_ENOMSG          83              /* No message of desired type */
#define VKI_EOVERFLOW       84              /* Value too large to be stored in data type */
#define VKI_ECANCELED       85              /* Operation canceled */
#define VKI_EILSEQ          86              /* Illegal byte sequence */
#define VKI_ENOATTR         87              /* Attribute not found */
#define VKI_EDOOFUS         88              /* Programming error */
#define VKI_EBADMSG         89              /* Bad message */
#define VKI_EMULTIHOP       90              /* Multihop attempted */
#define VKI_ENOLINK         91              /* Link has been severed */
#define VKI_EPROTO          92              /* Protocol error */
#define VKI_ENOTCAPABLE     93              /* Capabilities insufficient */
#define VKI_ECAPMODE        94              /* Not permitted in capability mode */

//----------------------------------------------------------------------
// From sys/wait.h
//----------------------------------------------------------------------

#define VKI_WNOHANG  0x00000001

typedef enum vki_idtype {
   VKI_P_PID,
   VKI_P_PPID,
   VKI_P_PGID,
   VKI_P_SID,
   VKI_P_CID,
   VKI_P_UID,
   VKI_P_GID,
   VKI_P_ALL,
   VKI_P_LWPID,
   VKI_P_TASKID,
   VKI_P_PROJID,
   VLI_P_POOLID,
   VKI_P_JAILID,
   VKI_P_CTID,
   VKI_P_CPUID,
   VKI_P_PSETID
} vki_idtype_t;

//----------------------------------------------------------------------
// From sys/mman.h
//----------------------------------------------------------------------

#define VKI_PROT_NONE   0x00     /* No page permissions */
#define VKI_PROT_READ   0x01     /* page can be read */
#define VKI_PROT_WRITE  0x02     /* page can be written */
#define VKI_PROT_EXEC   0x04     /* page can be executed */

#define VKI_MAP_SHARED  0x01     /* Share changes */
#define VKI_MAP_PRIVATE 0x02     /* Changes are private */
#define VKI_MAP_FIXED   0x10     /* Interpret addr exactly */
#define VKI_MAP_NORESERVE  0x0040      /* don't check for reservations */
#define  VKI_MAP_STACK  0x400
#define VKI_MAP_ANON 0x1000   /* don't use a file */
#define  VKI_MAP_ANONYMOUS VKI_MAP_ANON

//----------------------------------------------------------------------
// From sys/stat.h
//----------------------------------------------------------------------

#define VKI_S_IFMT  00170000

#define VKI_S_IFWHT  0160000
#define VKI_S_IFSOCK 0140000
#define VKI_S_IFLNK  0120000
#define VKI_S_IFREG  0100000
#define VKI_S_IFBLK  0060000
#define VKI_S_IFDIR  0040000
#define VKI_S_IFCHR  0020000
#define VKI_S_IFIFO  0010000
#define VKI_S_ISUID  0004000
#define VKI_S_ISGID  0002000
#define VKI_S_ISTXT  0001000

#define VKI_S_ISLNK(m)  (((m) & VKI_S_IFMT) == VKI_S_IFLNK)
#define VKI_S_ISREG(m)  (((m) & VKI_S_IFMT) == VKI_S_IFREG)
#define VKI_S_ISDIR(m)  (((m) & VKI_S_IFMT) == VKI_S_IFDIR)
#define VKI_S_ISCHR(m)  (((m) & VKI_S_IFMT) == VKI_S_IFCHR)
#define VKI_S_ISBLK(m)  (((m) & VKI_S_IFMT) == VKI_S_IFBLK)
#define VKI_S_ISFIFO(m) (((m) & VKI_S_IFMT) == VKI_S_IFIFO)
#define VKI_S_ISSOCK(m) (((m) & VKI_S_IFMT) == VKI_S_IFSOCK)
#define VKI_S_ISWHT(m)  (((m) & VKI_S_IFMT) == VKI_S_IFWHT)

#define VKI_S_IRWXU 00700
#define VKI_S_IRUSR 00400
#define VKI_S_IWUSR 00200
#define VKI_S_IXUSR 00100

#define VKI_S_IRWXG 00070
#define VKI_S_IRGRP 00040
#define VKI_S_IWGRP 00020
#define VKI_S_IXGRP 00010

#define VKI_S_IRWXO 00007
#define VKI_S_IROTH 00004
#define VKI_S_IWOTH 00002
#define VKI_S_IXOTH 00001


//----------------------------------------------------------------------
// From sys/dirent.h
//----------------------------------------------------------------------

struct vki_dirent {
   vki_uint32_t   d_fileno;
   vki_uint16_t   d_reclen;
   vki_uint8_t d_type;
   vki_uint8_t d_namelen;
   char     vki_d_name[256]; /* We must not include limits.h! */
};

//----------------------------------------------------------------------
// From sys/fcntl.h
//----------------------------------------------------------------------

#define VKI_O_RDONLY   O_RDONLY
#define VKI_O_WRONLY   O_WRONLY
#define VKI_O_RDWR     O_RDWR

#define VKI_FREAD FREAD
#define VKI_WRITE WRITE

#define VKI_O_NONBLOCK    O_NONBLOCK
#define VKI_O_APPEND   O_APPEND
#define VKI_O_CREAT    O_CREAT
#define VKI_O_TRUNC    O_TRUNC
#define VKI_O_EXCL     O_EXCL
#define VKI_O_DIRECTORY	O_DIRECTORY
#define VKI_O_EXEC      O_EXEC
#define VKI_O_SEARCH	O_EXEC

#define VKI_AT_FDCWD            AT_FDCWD
#define VKI_AT_SYMLINK_NOFOLLOW 0x0200


#define VKI_F_DUPFD     0  /* dup */
#define VKI_F_GETFD     1  /* get close_on_exec */
#define VKI_F_SETFD     2  /* set/clear close_on_exec */
#define VKI_F_GETFL     3  /* get file->f_flags */
#define VKI_F_SETFL     4  /* set file->f_flags */
#define VKI_F_SETOWN    5  /*  for sockets. */
#define VKI_F_GETOWN    6  /*  for sockets. */
#define VKI_F_OGETLK    7  /* get record locking information */
#define VKI_F_OSETLK    8  /* set record locking information */
#define VKI_F_OSETLKW   9  /* F_SETLK; wait if blocked */
#define VKI_F_DUP2FD    10 /* duplicate file descriptor to arg */
#define VKI_F_GETLK     11 /* get record locking information */
#define VKI_F_SETLK     12 /* set record locking information */
#define VKI_F_SETLKW    13 /* F_SETLK; wait if blocked */
#define VKI_F_SETLK_REMOTE 14 /* debugging support for remote locks */
#define VKI_F_READAHEAD    15 /* read ahead */
#define VKI_F_RDAHEAD      16 /* Darwin compatible read ahead */
#define VKI_F_DUPFD_CLOEXEC  17 /* dup close_on_exec */
#define VKI_F_DUP2FD_CLOEXEC 18 /* Like F_DUP2FD, but FD_CLOEXEC is set */
#define VKI_F_ADD_SEALS    19 /* apply seals to underlying file */
#define VKI_F_GET_SEALS    20 /* get seals to underlying file */
#define VKI_F_ISUNIONSTACK 21 /* kludge for libc (part of a union stack?) */
/* FreeBSD 13.1 and later */
#define VKI_F_KINFO        22 /* Return kinfo_file for this fd */

/* for F_[GET|SET]FL */
#define VKI_FD_CLOEXEC  1  /* actually anything with low bit set goes */

/* for F_[ADD|GET]_SEALS */
#define VKI_F_SEAL_SEAL    0x0001
#define VKI_F_SEAL_SHRINK  0x0002
#define VKI_F_SEAL_GROW    0x0004
#define VKI_F_SEAL_WRITE   0x0008

//----------------------------------------------------------------------
// From sys/unistd.h
//----------------------------------------------------------------------

#define VKI_SEEK_SET              0
#define VKI_SEEK_CUR              1
#define VKI_SEEK_END              2

#define VKI_F_OK  0       /* test for existence of file */
#define VKI_X_OK  0x01    /* test for execute or search permission */
#define VKI_W_OK  0x02    /* test for write permission */
#define VKI_R_OK  0x04    /* test for read permission */

#define VKI_RFSPAWN         (1U<<31U)

#define VKI_CLOSE_RANGE_CLOEXEC     (1<<2)

//----------------------------------------------------------------------
// From sys/msg.h
//----------------------------------------------------------------------

#if 0 /* not in freebsd */
#define VKI_MSGSND              11
#define VKI_MSGRCV              12
#define VKI_MSGGET              13
#define VKI_MSGCTL              14
#endif

typedef unsigned long vki_msglen_t;
typedef unsigned long vki_msgqnum_t;

struct vki_msqid_ds_old {
   struct vki_ipc_perm_old msg_perm;
   struct vki_msg *msg_first;
   struct vki_msg *msg_last;
   vki_msglen_t msg_cbytes;
   vki_msgqnum_t msg_qnum;
   vki_msglen_t msg_qbytes;
   vki_pid_t   msg_lspid;
   vki_pid_t   msg_lrpid;
   vki_time_t  msg_stime;
   vki_uint32_t   msg_pad1;
   vki_time_t  msg_rtime;
   vki_uint32_t   msg_pad2;
   vki_time_t  msg_ctime;
   vki_uint32_t   msg_pad3;
   vki_uint32_t   msg_pad4[4];
};

struct vki_msqid_ds {
   struct vki_ipc_perm msg_perm;
   struct vki_msg *msg_first;
   struct vki_msg *msg_last;
   vki_msglen_t msg_cbytes;
   vki_msgqnum_t msg_qnum;
   vki_msglen_t msg_qbytes;
   vki_pid_t   msg_lspid;
   vki_pid_t   msg_lrpid;
   vki_time_t  msg_stime;
   vki_time_t  msg_rtime;
   vki_time_t  msg_ctime;
};


struct vki_msgbuf {
   long mtype;         /* type of message */
   char mtext[1];      /* message text */
};


//----------------------------------------------------------------------
// From sys/shm.h
//----------------------------------------------------------------------

struct vki_shmid_ds_old {
   struct vki_ipc_perm_old shm_perm;   /* operation perms */
   int         shm_segsz;  /* size of segment (bytes) */
   vki_pid_t      shm_lpid;   /* pid of last operator */
   vki_pid_t      shm_cpid;   /* pid of creator */
   short       shm_nattch; /* no. of current attaches */
   vki_time_t     shm_atime;  /* last attach time */
   vki_time_t     shm_dtime;  /* last detach time */
   vki_time_t     shm_ctime;  /* last change time */
   void        *shm_internal; /* sysv stupidity */
};


struct vki_shmid_ds {
   struct vki_ipc_perm  shm_perm;   /* operation perms */
   vki_size_t     shm_segsz;  /* size of segment (bytes) */
   vki_pid_t      shm_lpid;   /* pid of last operator */
   vki_pid_t      shm_cpid;   /* pid of creator */
   int         shm_nattch; /* no. of current attaches */
   vki_time_t     shm_atime;  /* last attach time */
   vki_time_t     shm_dtime;  /* last detach time */
   vki_time_t     shm_ctime;  /* last change time */
};

#define VKI_SHMLBA  VKI_PAGE_SIZE
#define VKI_SHM_RDONLY  010000  /* read-only access */
#define  VKI_SHM_ANON   (1UL)

#if 0 /* not in freebsd abi */
#define VKI_SHMAT               21
#define VKI_SHMDT               22
#define VKI_SHMGET              23
#define VKI_SHMCTL              24
#endif

#if 0
//----------------------------------------------------------------------
// From linux-2.6.8.1/include/linux/sockios.h
//----------------------------------------------------------------------

#define VKI_SIOCOUTQ    VKI_TIOCOUTQ

#define VKI_SIOCADDRT      0x890B   /* add routing table entry */
#define VKI_SIOCDELRT      0x890C   /* delete routing table entry */

#define VKI_SIOCGIFNAME    0x8910   /* get iface name    */
#define VKI_SIOCGIFCONF    0x8912   /* get iface list    */
#define VKI_SIOCGIFFLAGS   0x8913   /* get flags         */
#define VKI_SIOCSIFFLAGS   0x8914   /* set flags         */
#define VKI_SIOCGIFADDR    0x8915   /* get PA address    */
#define VKI_SIOCSIFADDR    0x8916   /* set PA address    */
#define VKI_SIOCGIFDSTADDR 0x8917   /* get remote PA address   */
#define VKI_SIOCSIFDSTADDR 0x8918   /* set remote PA address   */
#define VKI_SIOCGIFBRDADDR 0x8919   /* get broadcast PA address   */
#define VKI_SIOCSIFBRDADDR 0x891a   /* set broadcast PA address   */
#define VKI_SIOCGIFNETMASK 0x891b   /* get network PA mask     */
#define VKI_SIOCSIFNETMASK 0x891c   /* set network PA mask     */
#define VKI_SIOCGIFMETRIC  0x891d   /* get metric        */
#define VKI_SIOCSIFMETRIC  0x891e   /* set metric        */
#define VKI_SIOCGIFMTU     0x8921   /* get MTU size         */
#define VKI_SIOCSIFMTU     0x8922   /* set MTU size         */
#define  VKI_SIOCSIFHWADDR 0x8924   /* set hardware address    */
#define VKI_SIOCGIFHWADDR  0x8927   /* Get hardware address    */
#define VKI_SIOCGIFINDEX   0x8933   /* name -> if_index mapping   */

#define VKI_SIOCGIFTXQLEN  0x8942   /* Get the tx queue length */
#define VKI_SIOCSIFTXQLEN  0x8943   /* Set the tx queue length    */

#define VKI_SIOCGMIIPHY    0x8947   /* Get address of MII PHY in use. */
#define VKI_SIOCGMIIREG    0x8948   /* Read MII PHY register.  */
#define VKI_SIOCSMIIREG    0x8949   /* Write MII PHY register. */

#define VKI_SIOCDARP    0x8953   /* delete ARP table entry  */
#define VKI_SIOCGARP    0x8954   /* get ARP table entry     */
#define VKI_SIOCSARP    0x8955   /* set ARP table entry     */

#define VKI_SIOCDRARP      0x8960   /* delete RARP table entry */
#define VKI_SIOCGRARP      0x8961   /* get RARP table entry    */
#define VKI_SIOCSRARP      0x8962   /* set RARP table entry    */

#define VKI_SIOCGIFMAP     0x8970   /* Get device parameters   */
#define VKI_SIOCSIFMAP     0x8971   /* Set device parameters   */

//----------------------------------------------------------------------
// From linux-2.6.9/include/linux/kb.h
//----------------------------------------------------------------------

#define VKI_GIO_FONT       0x4B60  /* gets font in expanded form */
#define VKI_PIO_FONT       0x4B61  /* use font in expanded form */

#define VKI_GIO_FONTX      0x4B6B  /* get font using struct consolefontdesc */
#define VKI_PIO_FONTX      0x4B6C  /* set font using struct consolefontdesc */
struct vki_consolefontdesc {
   unsigned short charcount;  /* characters in font (256 or 512) */
   unsigned short charheight; /* scan lines per character (1-32) */
   char __user *chardata;     /* font data in expanded form */
};

#define VKI_PIO_FONTRESET  0x4B6D  /* reset to default font */

#define VKI_GIO_CMAP       0x4B70  /* gets colour palette on VGA+ */
#define VKI_PIO_CMAP       0x4B71  /* sets colour palette on VGA+ */

#define VKI_KIOCSOUND      0x4B2F  /* start sound generation (0 for off) */
#define VKI_KDMKTONE       0x4B30  /* generate tone */

#define VKI_KDGETLED       0x4B31  /* return current led state */
#define VKI_KDSETLED       0x4B32  /* set led state [lights, not flags] */

#define VKI_KDGKBTYPE      0x4B33  /* get keyboard type */

#define VKI_KDADDIO        0x4B34  /* add i/o port as valid */
#define VKI_KDDELIO        0x4B35  /* del i/o port as valid */
#define VKI_KDENABIO       0x4B36  /* enable i/o to video board */
#define VKI_KDDISABIO      0x4B37  /* disable i/o to video board */

#define VKI_KDSETMODE      0x4B3A  /* set text/graphics mode */
#define VKI_KDGETMODE      0x4B3B  /* get current mode */

#define VKI_KDMAPDISP      0x4B3C  /* map display into address space */
#define VKI_KDUNMAPDISP    0x4B3D  /* unmap display from address space */

#define     VKI_E_TABSZ    256
#define VKI_GIO_SCRNMAP    0x4B40  /* get screen mapping from kernel */
#define VKI_PIO_SCRNMAP    0x4B41  /* put screen mapping table in kernel */
#define VKI_GIO_UNISCRNMAP 0x4B69  /* get full Unicode screen mapping */
#define VKI_PIO_UNISCRNMAP 0x4B6A  /* set full Unicode screen mapping */

#define VKI_GIO_UNIMAP     0x4B66  /* get unicode-to-font mapping from kernel */
#define VKI_PIO_UNIMAP     0x4B67  /* put unicode-to-font mapping in kernel */
#define VKI_PIO_UNIMAPCLR  0x4B68  /* clear table, possibly advise hash algorithm */

#define VKI_KDGKBMODE      0x4B44  /* gets current keyboard mode */
#define VKI_KDSKBMODE      0x4B45  /* sets current keyboard mode */

#define VKI_KDGKBMETA      0x4B62  /* gets meta key handling mode */
#define VKI_KDSKBMETA      0x4B63  /* sets meta key handling mode */

#define VKI_KDGKBLED       0x4B64  /* get led flags (not lights) */
#define VKI_KDSKBLED       0x4B65  /* set led flags (not lights) */

struct vki_kbentry {
   unsigned char kb_table;
   unsigned char kb_index;
   unsigned short kb_value;
};
#define VKI_KDGKBENT       0x4B46  /* gets one entry in translation table */
#define VKI_KDSKBENT       0x4B47  /* sets one entry in translation table */

struct vki_kbsentry {
   unsigned char kb_func;
   unsigned char kb_string[512];
};
#define VKI_KDGKBSENT      0x4B48  /* gets one function key string entry */
#define VKI_KDSKBSENT      0x4B49  /* sets one function key string entry */

struct vki_kbdiacr {
   unsigned char diacr, base, result;
};
struct vki_kbdiacrs {
   unsigned int kb_cnt;    /* number of entries in following array */
   struct vki_kbdiacr kbdiacr[256];    /* MAX_DIACR from keyboard.h */
};
#define VKI_KDGKBDIACR     0x4B4A  /* read kernel accent table */
#define VKI_KDSKBDIACR     0x4B4B  /* write kernel accent table */

struct vki_kbkeycode {
   unsigned int scancode, keycode;
};
#define VKI_KDGETKEYCODE   0x4B4C  /* read kernel keycode table entry */
#define VKI_KDSETKEYCODE   0x4B4D  /* write kernel keycode table entry */

#define VKI_KDSIGACCEPT    0x4B4E  /* accept kbd generated signals */

struct vki_kbd_repeat {
   int delay;  /* in msec; <= 0: don't change */
   int period; /* in msec; <= 0: don't change */
   /* earlier this field was misnamed "rate" */
};
#define VKI_KDKBDREP       0x4B52  /* set keyboard delay/repeat rate;
                                    * actually used values are returned */

#define VKI_KDFONTOP       0x4B72  /* font operations */

//----------------------------------------------------------------------
// From linux-2.6.9/include/linux/kb.h
//----------------------------------------------------------------------

typedef __vki_kernel_uid32_t vki_qid_t; /* Type in which we store ids in memory */

#endif

//----------------------------------------------------------------------
// From sys/ptrace.h
//----------------------------------------------------------------------

#define VKI_PTRACE_TRACEME         0
#define VKI_PTRACE_READ_I     1
#define VKI_PTRACE_READ_D     2
/* 3 - read user struct */
#define VKI_PTRACE_WRITE_I    4
#define VKI_PTRACE_WRITE_D    5
/* 6 - write user struct */
#define VKI_PTRACE_CONTINUE      7
#define VKI_PTRACE_KILL       8
#define VKI_PTRACE_STEP       9
#define VKI_PTRACE_ATTACH     10
#define VKI_PTRACE_DETACH     11
#define VKI_PTRACE_IO         12
#define VKI_PTRACE_LWPINFO    13
#define VKI_PTRACE_GETNUMLWPS    14
#define VKI_PTRACE_GETLWPLIST    15
#define VKI_PTRACE_CLEARSTEP     16
#define VKI_PTRACE_SETSTEP    17
#define VKI_PTRACE_SUSPEND    18
#define VKI_PTRACE_RESUME     19
#define VKI_PTRACE_TO_SCE     20
#define VKI_PTRACE_TO_SCX     21
#define VKI_PTRACE_SYSCALL    22
/* md */
#define VKI_PTRACE_GETREGS    33
#define VKI_PTRACE_SETREGS    34
#define VKI_PTRACE_GETFPREGS     35
#define VKI_PTRACE_SETFPREGS     36
#define VKI_PTRACE_GETDBREGS     37
#define VKI_PTRACE_SETDBREGS     38

#define  VKI_PTRACE_VM_TIMESTAMP    40
#define  VKI_PTRACE_VM_ENTRY        41

#define VKI_PTRACE_FIRSTMACH     64

struct vki_ptrace_io_desc {
   int      piod_op;
   void *      piod_offs;
   void *      piod_addr;
   vki_size_t  piod_len;
};
#define VKI_PIOD_READ_D    1
#define VKI_PIOD_WRITE_D   2
#define VKI_PIOD_READ_I    3
#define VKI_PIOD_WRITE_I   4

struct vki_ptrace_lwpinfo {
   vki_lwpid_t pl_lwpid;
   int      pl_event;
#define  VKI_PL_EVENT_NONE 0
#define  VKI_PL_EVENT_SIGNAL  1
   int      pl_flags;
#define VKI_FLAG_SA     0x01
#define  VKI_FLAG_BOUND    0x02
   vki_sigset_t pl_sigmask;
   vki_sigset_t pl_siglist;
};

struct vki_ptrace_vm_entry {
   int      pve_entry;  /* Entry number used for iteration. */
   int      pve_timestamp; /* Generation number of VM map. */
   unsigned long  pve_start;  /* Start VA of range. */
   unsigned long  pve_end; /* End VA of range (incl). */
   unsigned long  pve_offset; /* Offset in backing object. */
   unsigned int   pve_prot;   /* Protection of memory range. */
   unsigned int   pve_pathlen;   /* Size of path. */
   long     pve_fileid; /* File ID. */
   vki_uint32_t   pve_fsid;   /* File system ID. */
   char     *pve_path;  /* Path name of object. */
};

#endif // __VKI_FREEBSD_H

//----------------------------------------------------------------------
// From x86/sysarch.h
//----------------------------------------------------------------------

// @todo PJF missing VKI_I386_VM86 VKI_I386_SET_PKRU VKI_I386_CLEAR_PKRU VKI_AMD64_SET_PKRU VKI_AMD64_CLEAR_PKRU
#define VKI_I386_GET_FSBASE     7
#define VKI_I386_SET_FSBASE     8
#define VKI_I386_GET_GSBASE     9
#define VKI_I386_SET_GSBASE     10
#define VKI_I386_GET_XFPUSTATE  11

#define VKI_AMD64_GET_FSBASE    128
#define VKI_AMD64_SET_FSBASE    129
#define VKI_AMD64_GET_GSBASE    130
#define VKI_AMD64_SET_GSBASE    131
#define VKI_AMD64_GET_XFPUSTATE  132

//----------------------------------------------------------------------
// From sys/module.h
//----------------------------------------------------------------------

#define VKI_MAXMODNAME 32

typedef union vki_modspecific {
   vki_int32_t intval;
   vki_uint32_t   u_intval;
#if defined(VGP_x86_freebsd)
   vki_int32_t longval;
   vki_uint32_t   u_longval;
#elif defined(VGP_amd64_freebsd)
   vki_int64_t longval;
   vki_uint64_t   u_longval;
#else
#error Unknown platform
#endif
} vki_modspecific_t;

struct vki_module_stat {
   int   version;
   char  name[VKI_MAXMODNAME];
   int   refs;
   int   id;
   vki_modspecific_t data;
};

//----------------------------------------------------------------------
// From sys/rtprio.h
//----------------------------------------------------------------------

struct vki_rtprio {
   vki_uint16_t   type;
   vki_uint16_t   prio;
};

#define VKI_RTP_LOOKUP  0
#define VKI_RTP_SET  1

//----------------------------------------------------------------------
// From sys/umtx.h
//----------------------------------------------------------------------

struct vki_umtx {
   unsigned long  u_owner;
};

struct vki_umutex {
   vki_lwpid_t m_owner;
   vki_uint32_t   m_flags;
   vki_uint32_t   m_ceilings[2];
   vki_uint32_t   m_spare[4];
};

struct vki_ucond {
   vki_uint32_t   c_has_waiters;
   vki_uint32_t   c_flags;
   vki_uint32_t   c_spare[2];
};

struct vki_urwlock {
   vki_uint32_t   rw_state;
   vki_uint32_t   rw_flags;
   vki_uint32_t   rw_blocked_readers;
   vki_uint32_t   rw_blocked_writers;
   vki_uint32_t   rw_spare[4];
};

struct vki_usem {
   vki_uint32_t   has_waiters;
   vki_uint32_t   count;
   vki_uint32_t   flags;
};

struct vki_umtx_time {
   struct vki_timespec  timeout;
   vki_uint32_t      flags;
   vki_uint32_t      clockid;
};

struct vki_usem2 {
   vki_uint32_t    count;
   vki_uint32_t  flags;
};

struct vki_umtx_robust_lists_params {
   vki_uintptr_t robust_list_offset;
   vki_uintptr_t robust_priv_list_offset;
   vki_uintptr_t robust_inact_offset;
};

#define VKI_UMTX_OP_LOCK     0
#define VKI_UMTX_OP_UNLOCK      1
#define VKI_UMTX_OP_WAIT     2
#define VKI_UMTX_OP_WAKE     3
#define VKI_UMTX_OP_MUTEX_TRYLOCK  4
#define VKI_UMTX_OP_MUTEX_LOCK     5
#define VKI_UMTX_OP_MUTEX_UNLOCK   6
#define VKI_UMTX_OP_SET_CEILING    7
#define VKI_UMTX_OP_CV_WAIT     8
#define VKI_UMTX_OP_CV_SIGNAL      9
#define VKI_UMTX_OP_CV_BROADCAST   10
#define VKI_UMTX_OP_WAIT_UINT      11
#define VKI_UMTX_OP_RW_RDLOCK      12
#define VKI_UMTX_OP_RW_WRLOCK      13
#define VKI_UMTX_OP_RW_UNLOCK      14
#define VKI_UMTX_OP_WAIT_UINT_PRIVATE 15
#define VKI_UMTX_OP_WAKE_PRIVATE   16
#define VKI_UMTX_OP_MUTEX_WAIT     17
#define VKI_UMTX_OP_MUTEX_WAKE     18 /* deprecated */
#define VKI_UMTX_OP_SEM_WAIT    19
#define VKI_UMTX_OP_SEM_WAKE    20
#define VKI_UMTX_OP_NWAKE_PRIVATE  21
#define VKI_UMTX_OP_MUTEX_WAKE2    22
#define VKI_UMTX_OP_SEM2_WAIT       23
#define VKI_UMTX_OP_SEM2_WAKE       24
#define VKI_UMTX_OP_SHM             25
#define VKI_UMTX_OP_ROBUST_LISTS    26
#if (FREEBSD_VERS >= FREEBSD_14)
#define VKI_UMTX_OP_GET_MIN_TIMEOUT 27
#define VKI_UMTX_OP_SET_MIN_TIMEOUT 28
#endif


//----------------------------------------------------------------------
// From sys/acl.h
//----------------------------------------------------------------------

struct vki_acl_entry {
   int      ae_tag;
   vki_uid_t   ae_uid;
   vki_mode_t  ae_perm;
};

#define VKI_ACL_MAX_ENTRIES 32
struct vki_acl {
   int      acl_cnt;
   struct vki_acl_entry acl_entry[VKI_ACL_MAX_ENTRIES];
};


//----------------------------------------------------------------------
// From sys/uuid.h
//----------------------------------------------------------------------

struct vki_uuid {
   vki_uint32_t   time_low;
   vki_uint16_t   time_mid;
   vki_uint16_t   time_hi_and_version;
   vki_uint8_t clock_seq_hi_and_reserved;
   vki_uint8_t clock_seq_low;
   vki_uint8_t node[6];
};

//----------------------------------------------------------------------
// sys/_sockaddr_storage.h
//----------------------------------------------------------------------

#define VKI__SS_MAXSIZE     128U
#define VKI__SS_ALIGNSIZE   (sizeof(__int64_t))
#define VKI__SS_PAD1SIZE    (VKI__SS_ALIGNSIZE - sizeof(unsigned char) - \
                            sizeof(vki_sa_family_t))
#define VKI__SS_PAD2SIZE    (VKI__SS_MAXSIZE - sizeof(unsigned char) - \
                            sizeof(sa_family_t) - VKI__SS_PAD1SIZE - VKI__SS_ALIGNSIZE)

struct vki_sockaddr_storage {
        unsigned char   vki_ss_len;         /* address length */
        vki_sa_family_t     vki_ss_family;      /* address family */
        char            vki___ss_pad1[VKI__SS_PAD1SIZE];
        __int64_t       vki___ss_align;     /* force desired struct alignment */
        char            vki___ss_pad2VKI_[_SS_PAD2SIZE];
};

//----------------------------------------------------------------------
// From sys/captrights.h
//----------------------------------------------------------------------

#define VKI_CAP_RIGHTS_VERSION_00   0
#define VKI_CAP_RIGHTS_VERSION      VKI_CAP_RIGHTS_VERSION_00

struct vki_cap_rights {
        vki_uint64_t        cki_cr_rights[VKI_CAP_RIGHTS_VERSION + 2];
};

typedef struct vki_cap_rights       vki_cap_rights_t;


//----------------------------------------------------------------------
// From sys/user.h
//----------------------------------------------------------------------

#define VKI_KVME_TYPE_NONE          0
#define VKI_KVME_TYPE_DEFAULT       1
#define VKI_KVME_TYPE_VNODE         2
#define VKI_KVME_TYPE_SWAP          3
#define VKI_KVME_TYPE_DEVICE        4
#define VKI_KVME_TYPE_PHYS          5
#define VKI_KVME_TYPE_DEAD          6
#define VKI_KVME_TYPE_UNKNOWN       255

#define VKI_KVME_PROT_READ          0x00000001
#define VKI_KVME_PROT_WRITE         0x00000002
#define VKI_KVME_PROT_EXEC          0x00000004

#define VKI_KVME_FLAG_COW           0x00000001
#define VKI_KVME_FLAG_NEEDS_COPY    0x00000002

struct vki_kinfo_vmentry {
   int   kve_structsize;
   int   kve_type;
   ULong kve_start;
   ULong kve_end;
   ULong   kve_offset;
   ULong   kve_fileid;
   UInt    kve_vn_fsid_freebsd11;
   int   kve_flags;
   int   kve_resident;
   int   kve_private_resident;
   int   kve_protection;
   int   kve_ref_count;
   int   kve_shadow_count;
   int      kve_vn_type;
   ULong kve_vn_size;
   UInt kve_vn_rdev_freebsd11;
   UShort kve_vn_mode;
   UShort kve_status;
   ULong kve_vn_fsid;
   ULong kve_vn_rdev;
   int      _kve_ispare[8];
   char  kve_path[VKI_PATH_MAX];
};

#define	VKI_KINFO_FILE_SIZE	1392

struct vki_kinfo_file {
   int		vki_kf_structsize;		/* Variable size of record. */
   int		vki_kf_type;		/* Descriptor type. */
   int		vki_kf_fd;			/* Array index. */
   int		vki_kf_ref_count;		/* Reference count. */
   int		vki_kf_flags;		/* Flags. */
   int		vki_kf_pad0;		/* Round to 64 bit alignment. */
   Off64T   vki_kf_offset;		/* Seek location. */
   union {
      struct {
         /* API compatiblity with FreeBSD < 12. */
         int		vki_kf_vnode_type;
         int		vki_kf_sock_domain;
         int		vki_kf_sock_type;
         int		kf_sock_protocol;
         struct vki_sockaddr_storage vki_kf_sa_local;
         struct vki_sockaddr_storage	vki_kf_sa_peer;
      };
      union {
         struct {
            /* Sendq size */
            vki_uint32_t	vki_kf_sock_sendq;
            /* Socket domain. */
            int		vki_kf_sock_domain0;
            /* Socket type. */
            int		vki_kf_sock_type0;
            /* Socket protocol. */
            int		vki_kf_sock_protocol0;
            /* Socket address. */
            struct vki_sockaddr_storage vki_kf_sa_local;
            /* Peer address. */
            struct vki_sockaddr_storage	vki_kf_sa_peer;
            /* Address of so_pcb. */
            vki_uint64_t	vki_kf_sock_pcb;
            /* Address of inp_ppcb. */
            vki_uint64_t	vki_kf_sock_inpcb;
            /* Address of unp_conn. */
            vki_uint64_t	vki_kf_sock_unpconn;
            /* Send buffer state. */
            vki_uint16_t	vki_kf_sock_snd_sb_state;
            /* Receive buffer state. */
            vki_uint16_t	vki_kf_sock_rcv_sb_state;
            /* Recvq size. */
            vki_uint32_t	vki_kf_sock_recvq;
         } vki_kf_sock;
         struct {
            /* Vnode type. */
            int		vki_kf_file_type;
            /* Space for future use */
            int		vki_kf_spareint[3];
            vki_uint64_t	vki_kf_spareint64[30];
            /* Vnode filesystem id. */
            vki_uint64_t	vki_kf_file_fsid;
            /* File device. */
            vki_uint64_t	vki_kf_file_rdev;
            /* Global file id. */
            vki_uint64_t	vki_kf_file_fileid;
            /* File size. */
            vki_uint64_t	vki_kf_file_size;
            /* Vnode filesystem id, FreeBSD 11 compat. */
            vki_uint32_t	vki_kf_file_fsid_freebsd11;
            /* File device, FreeBSD 11 compat. */
            vki_uint32_t	kf_file_rdev_freebsd11;
            /* File mode. */
            vki_uint16_t	vki_kf_file_mode;
            /* Round to 64 bit alignment. */
            vki_uint16_t	vki_kf_file_pad0;
            vki_uint32_t	kf_file_pad1;
         } kf_file;
         struct {
            vki_uint32_t	vki_kf_spareint[4];
            vki_uint64_t	vki_kf_spareint64[32];
            vki_uint32_t	vki_kf_sem_value;
            vki_uint16_t	vki_kf_sem_mode;
         } kf_sem;
         struct {
            vki_uint32_t	vki_kf_spareint[4];
            vki_uint64_t	vki_kf_spareint64[32];
            vki_uint64_t	vki_kf_pipe_addr;
            vki_uint64_t	vki_kf_pipe_peer;
            vki_uint32_t	vki_kf_pipe_buffer_cnt;
            /* Round to 64 bit alignment. */
            vki_uint32_t	vki_kf_pipe_pad0[3];
         } kf_pipe;
         struct {
            vki_uint32_t	vki_kf_spareint[4];
            vki_uint64_t	vki_kf_spareint64[32];
            vki_uint32_t	vki_kf_pts_dev_freebsd11;
            vki_uint32_t	vki_kf_pts_pad0;
            vki_uint64_t	vki_kf_pts_dev;
            /* Round to 64 bit alignment. */
            vki_uint32_t	vki_kf_pts_pad1[4];
         } kf_pts;
         struct {
            vki_uint32_t	vki_kf_spareint[4];
            vki_uint64_t	vki_kf_spareint64[32];
            vki_pid_t		vki_kf_pid;
         } vki_kf_proc;
         struct {
            vki_uint64_t	vki_kf_eventfd_value;
            vki_uint32_t	vki_kf_eventfd_flags;
         } vki_kf_eventfd;
      } vki_kf_un;
   };
   vki_uint16_t	vki_kf_status;		/* Status flags. */
   vki_uint16_t	vki_kf_pad1;		/* Round to 32 bit alignment. */
   int		vki__kf_ispare0;		/* Space for more stuff. */
   vki_cap_rights_t	vki_kf_cap_rights;		/* Capability rights. */
   vki_uint64_t	vki__kf_cap_spare;		/* Space for future cap_rights_t. */
   /* Truncated before copyout in sysctl */
   char		vki_kf_path[VKI_PATH_MAX];	/* Path to file, if any. */
};

//----------------------------------------------------------------------
// From sys/kenv.h
//----------------------------------------------------------------------
#define VKI_KENV_GET    0
#define VKI_KENV_SET    1
#define VKI_KENV_UNSET     2
#define VKI_KENV_DUMP      3

//----------------------------------------------------------------------
// From sys/sysctl.h (and related)
//----------------------------------------------------------------------

#include <sys/types.h>
#include <sys/sysctl.h>

#define VKI_CTL_KERN         CTL_KERN
#define VKI_CTL_HW           CTL_HW
#define VKI_KERN_PROC        KERN_PROC
#define VKI_KERN_PROC_VMMAP  KERN_PROC_VMMAP
#define VKI_KERN_PROC_FILEDESC KERN_PROC_FILEDESC
#define VKI_HW_MACHINE       HW_MACHINE

//----------------------------------------------------------------------
// From sys/thr.h
//----------------------------------------------------------------------

struct vki_thr_param {
   void  (*start_func)(void *);
   void  *arg;
   char  *stack_base;
   vki_size_t  stack_size;
   char  *tls_base;
   vki_size_t  tls_size;
   long  *child_tid;
   long  *parent_tid;
   int   flags;
   struct vki_rtprio *rtp;
   void  *spare[3];
};

//----------------------------------------------------------------------
// From sys/linker.h
//----------------------------------------------------------------------

struct vki_kld_file_stat {
   int         version;        /* set to sizeof(struct kld_file_stat) */
   char        name[MAXPATHLEN];
   int         refs;
   int         id;
   vki_caddr_t     address;        /* load address */
   vki_size_t      size;           /* size in bytes */
   char        pathname[MAXPATHLEN];
};


struct vki_kld_sym_lookup {
   int         version;        /* set to sizeof(struct kld_sym_lookup) */
   char        *symname;       /* Symbol name we are looking up */
   unsigned long symvalue;
   vki_size_t  symsize;
};

#if !defined(VKI_INIT_ARCH_ELF_STATE)
/* This structure is used to preserve architecture specific data during
   the loading of an ELF file, throughout the checking of architecture
   specific ELF headers & through to the point where the ELF load is
   known to be proceeding. This implementation is a dummy for
   architectures which require no specific state. */
struct vki_arch_elf_state {
};

#  define VKI_INIT_ARCH_ELF_STATE { }

#endif

//----------------------------------------------------------------------
// From ufs/ufs/quota.h
//----------------------------------------------------------------------

#define VKI_Q_QUOTAON       0x0100
#define VKI_Q_QUOTAOFF      0x0200
#define VKI_Q_GETQUOTA32    0x0300
#define VKI_Q_SETQUOTA32    0x0400
#define VKI_Q_SETUSE32      0x0500
#define VKI_Q_SYNC          0x0600
#define VKI_Q_GETQUOTA      0x0700
#define VKI_Q_SETQUOTA      0x0800
#define VKI_Q_SETUSE        0x0900
#define VKI_Q_GETQUOTASIZE  0x0A00

//----------------------------------------------------------------------
// From sys/_bitset.h
//----------------------------------------------------------------------

#define  VKI_BITSET_BITS      (sizeof(long) * 8)

#define  vki__howmany(x, y)   (((x) + ((y) - 1)) / (y))

#define  vki__bitset_words(_s)   (vki__howmany(_s, VKI_BITSET_BITS))

#define  VKI_BITSET_DEFINE(t, _s)                  \
struct t {                       \
        long    __bits[vki__bitset_words((_s))];            \
}

//----------------------------------------------------------------------
// From sys/_domainset.h
//----------------------------------------------------------------------

#define  VKI_DOMAINSET_MAXSIZE   256

#ifndef  VKI_DOMAINSET_SETSIZE
#define  VKI_DOMAINSET_SETSIZE   VKI_DOMAINSET_MAXSIZE
#endif

VKI_BITSET_DEFINE(vki_domainset, VKI_DOMAINSET_SETSIZE);

typedef struct vki_domainset vki_domainset_t;

//----------------------------------------------------------------------
// From sys/procctl.h
//----------------------------------------------------------------------

#define VKI_PROC_SPROTECT           1
#define VKI_PROC_REAP_ACQUIRE       2
#define VKI_PROC_REAP_RELEASE       3
#define VKI_PROC_REAP_STATUS        4
#define VKI_PROC_REAP_GETPIDS       5
#define VKI_PROC_REAP_KILL          6
#define VKI_PROC_TRACE_CTL          7
#define VKI_PROC_TRACE_STATUS       8
#define VKI_PROC_TRAPCAP_CTL        9
#define VKI_PROC_TRAPCAP_STATUS     10
#define VKI_PROC_PDEATHSIG_CTL      11
#define VKI_PROC_PDEATHSIG_STATUS   12
#define VKI_PROC_ASLR_CTL           13
#define VKI_PROC_ASLR_STATUS        14
#define VKI_PROC_STACKGAP_CTL       17
#define VKI_PROC_STACKGAP_STATUS    18
#define VKI_PROC_NO_NEW_PRIVS_CTL   19
#define VKI_PROC_NO_NEW_PRIVS_STATUS 20
#define VKI_PROC_WXMAP_CTL          21
#define VKI_PROC_WXMAP_STATUS       22

struct vki_procctl_reaper_status {
   u_int   rs_flags;
   u_int   rs_children;
   u_int   rs_descendants;
   vki_pid_t   rs_reaper;
   vki_pid_t   rs_pid;
   u_int   rs_pad0[15];
};

struct vki_procctl_reaper_pidinfo;

struct vki_procctl_reaper_pids {
   u_int   rp_count;
   u_int   rp_pad0[15];
   struct vki_procctl_reaper_pidinfo *rp_pids;
};

struct vki_procctl_reaper_kill {
   int     rk_sig;
   u_int   rk_flags;
   vki_pid_t   rk_subtree;
   u_int   rk_killed;
   vki_pid_t   rk_fpid;
   u_int   rk_pad0[15];
};

//----------------------------------------------------------------------
// From sys/jail.h
//----------------------------------------------------------------------

struct vki_jail {
   uint32_t        version;
   char            *path;
   char            *hostname;
   char            *jailname;
   uint32_t        ip4s;
   uint32_t        ip6s;
   struct in_addr  *ip4;
   struct in6_addr *ip6;
};

//----------------------------------------------------------------------
// From sys/exec.h
//----------------------------------------------------------------------

struct vki_ps_strings {
   char** ps_argvstr;
   unsigned int ps_nargvstr;

   char** ps_envstr;
   unsigned int ps_nenvstr;
};

//----------------------------------------------------------------------
// From sys/elf_common.h
//----------------------------------------------------------------------

#define VKI_AT_NULL 0
#define VKI_AT_IGNORE 1
#define VKI_AT_EXECFD 2
#define VKI_AT_PHDR 3
#define VKI_AT_PHENT 4
#define VKI_AT_PHNUM 5
#define VKI_AT_PAGESZ 6
#define VKI_AT_BASE 7
#define VKI_AT_FLAGS 8
#define VKI_AT_ENTRY 9
#define VKI_AT_NOTELF 10
#define VKI_AT_UID 11
#define VKI_AT_EUID 12
#define VKI_AT_GID 13
#define VKI_AT_EGID 14
#define VKI_AT_EXECPATH 15
#define VKI_AT_CANARY 16
#define VKI_AT_CANARYLEN 17
#define VKI_AT_OSRELDATE 18
#define VKI_AT_NCPUS	19
#define VKI_AT_PAGESIZES 20
#define VKI_AT_PAGESIZESLEN 21
#define VKI_AT_TIMEKEEP 22
#define VKI_AT_STACKPROT 23
#define VKI_AT_EHDRFLAGS 24
#define VKI_AT_HWCAP 25
#define VKI_AT_HWCAP2 26
/* added in FreeBSD 13 */
#define VKI_AT_BSDFLAGS 27
#define VKI_AT_ARGC 28
#define VKI_AT_ARGV 29
#define VKI_AT_ENVC 30
#define VKI_AT_ENVV 31
#define VKI_AT_PS_STRINGS 32
/* added in FreeBSD 13.1 */
#define VKI_AT_FXRNG	33
#define VKI_AT_KPRELOAD	34
/* added in FreeBSD 14 */
#define VKI_AT_USRSTACKBASE 35
#define VKI_AT_USRSTACKLIM 36

/* AT_COUNT depends on the FreeBSD version, not currently used */


#define VKI_NT_FREEBSD_ABI_TAG 1
#define VKI_NT_FREEBSD_FEATURE_CTL	4
#define VKI_NT_FREEBSD_FCTL_WXNEEDED	0x00000008

// See syswrap-freebsd.c PRE/POST(sys_ioctl)
#if 0

//----------------------------------------------------------------------
// From sys/pciio.h
//----------------------------------------------------------------------

typedef unsigned long vki_u_long;
typedef unsigned int vki_u_int;
#define VKI_PCI_MAXNAMELEN  16

typedef enum {
   VKI_PCI_GETCONF_LAST_DEVICE,
   VKI_PCI_GETCONF_LIST_CHANGED,
   VKI_PCI_GETCONF_MORE_DEVS,
   VKI_PCI_GETCONF_ERROR
} vki_pci_getconf_status;

typedef enum {
   VKI_PCI_GETCONF_NO_MATCH            = 0x0000,
   VKI_PCI_GETCONF_MATCH_DOMAIN        = 0x0001,
   VKI_PCI_GETCONF_MATCH_BUS           = 0x0002,
   VKI_PCI_GETCONF_MATCH_DEV           = 0x0004,
   VKI_PCI_GETCONF_MATCH_FUNC          = 0x0008,
   VKI_PCI_GETCONF_MATCH_NAME          = 0x0010,
   VKI_PCI_GETCONF_MATCH_UNIT          = 0x0020,
   VKI_PCI_GETCONF_MATCH_VENDOR        = 0x0040,
   VKI_PCI_GETCONF_MATCH_DEVICE        = 0x0080,
   VKI_PCI_GETCONF_MATCH_CLASS         = 0x0100
} vki_pci_getconf_flags;

struct vki_pcisel {
   vki_uint32_t   pc_domain;      /* domain number */
   vki_uint8_t    pc_bus;         /* bus number */
   vki_uint8_t    pc_dev;         /* device on this bus */
   vki_uint8_t    pc_func;        /* function on this device */
};

struct vki_pci_conf {
   struct vki_pcisel   pc_sel;         /* domain+bus+slot+function */
   vki_uint8_t    pc_hdr;         /* PCI header type */
   vki_uint16_t   pc_subvendor;   /* card vendor ID */
   vki_uint16_t   pc_subdevice;   /* card device ID, assigned by
                                           card vendor */
   vki_uint16_t   pc_vendor;      /* chip vendor ID */
   vki_uint16_t   pc_device;      /* chip device ID, assigned by
                                           chip vendor */
   vki_uint8_t    pc_class;       /* chip PCI class */
   vki_uint8_t    pc_subclass;    /* chip PCI subclass */
   vki_uint8_t    pc_progif;      /* chip PCI programming interface */
   vki_uint8_t    pc_revid;       /* chip revision ID */
   char        pd_name[VKI_PCI_MAXNAMELEN + 1];  /* device name */
   vki_u_long     pd_unit;        /* device unit number */
};

struct vki_pci_match_conf {
   struct vki_pcisel       pc_sel;         /* domain+bus+slot+function */
   char                pd_name[VKI_PCI_MAXNAMELEN + 1];  /* device name */
   vki_u_long             pd_unit;        /* Unit number */
   vki_uint16_t           pc_vendor;      /* PCI Vendor ID */
   vki_uint16_t           pc_device;      /* PCI Device ID */
   vki_uint8_t            pc_class;       /* PCI class */
   vki_pci_getconf_flags   flags;          /* Matching expression */
};

struct vki_pci_conf_io {
   vki_uint32_t           pat_buf_len;    /* pattern buffer length */
   vki_uint32_t           num_patterns;   /* number of patterns */
   struct vki_pci_match_conf   *patterns;      /* pattern buffer */
   vki_uint32_t           match_buf_len;  /* match buffer length */
   vki_uint32_t           num_matches;    /* number of matches returned */
   struct vki_pci_conf     *matches;       /* match buffer */
   vki_uint32_t           offset;         /* offset into device list */
   vki_uint32_t           generation;     /* device list generation */
   vki_pci_getconf_status  status;         /* request status */
};

#define VKI_PCIOCGETCONF    _VKI_IOWR('p', 5, struct vki_pci_conf_io)

//----------------------------------------------------------------------
// From cam/cam.h
//----------------------------------------------------------------------

#define VKI_CAM_MAX_CDBLEN 16

typedef unsigned int vki_path_id_t;
typedef unsigned int vki_target_id_t;
typedef unsigned int vki_lun_id_t;

typedef struct {
   vki_uint32_t priority;
   vki_uint32_t generation;
   int       index;
} vki_cam_pinfo;


//----------------------------------------------------------------------
// From sys/ata.h
//----------------------------------------------------------------------

struct vki_ata_params {
   /*000*/ vki_u_int16_t   config;         /* configuration info */
   /*001*/ vki_u_int16_t   cylinders;              /* # of cylinders */
   /*002*/ vki_u_int16_t   specconf;               /* specific configuration */
   /*003*/ vki_u_int16_t   heads;                  /* # heads */
   vki_u_int16_t   obsolete4;
   vki_u_int16_t   obsolete5;
   /*006*/ vki_u_int16_t   sectors;                /* # sectors/track */
   /*007*/ vki_u_int16_t   vendor7[3];
   /*010*/ vki_u_int8_t    serial[20];             /* serial number */
   /*020*/ vki_u_int16_t   retired20;
   vki_u_int16_t   retired21;
   vki_u_int16_t   obsolete22;
   /*023*/ vki_u_int8_t    revision[8];            /* firmware revision */
   /*027*/ vki_u_int8_t    model[40];              /* model name */
   /*047*/ vki_u_int16_t   sectors_intr;           /* sectors per interrupt */
   /*048*/ vki_u_int16_t   usedmovsd;              /* double word read/write? */
   /*049*/ vki_u_int16_t   capabilities1;
   /*050*/ vki_u_int16_t   capabilities2;
   /*051*/ vki_u_int16_t   retired_piomode;        /* PIO modes 0-2 */
   /*052*/ vki_u_int16_t   retired_dmamode;        /* DMA modes */
   /*053*/ vki_u_int16_t   atavalid;               /* fields valid */
   /*054*/ vki_u_int16_t   current_cylinders;
   /*055*/ vki_u_int16_t   current_heads;
   /*056*/ vki_u_int16_t   current_sectors;
   /*057*/ vki_u_int16_t   current_size_1;
   /*058*/ vki_u_int16_t   current_size_2;
   /*059*/ vki_u_int16_t   multi;
   /*060*/ vki_u_int16_t   lba_size_1;
   vki_u_int16_t   lba_size_2;
   vki_u_int16_t   obsolete62;
   /*063*/ vki_u_int16_t   mwdmamodes;             /* multiword DMA modes */
   /*064*/ vki_u_int16_t   apiomodes;              /* advanced PIO modes */

   /*065*/ vki_u_int16_t   mwdmamin;               /* min. M/W DMA time/word ns */
   /*066*/ vki_u_int16_t   mwdmarec;               /* rec. M/W DMA time ns */
   /*067*/ vki_u_int16_t   pioblind;               /* min. PIO cycle w/o flow */
   /*068*/ vki_u_int16_t   pioiordy;               /* min. PIO cycle IORDY flow */
   /*069*/ vki_u_int16_t   support3;
   vki_u_int16_t   reserved70;
   /*071*/ vki_u_int16_t   rlsovlap;               /* rel time (us) for overlap */
   /*072*/ vki_u_int16_t   rlsservice;             /* rel time (us) for service */
   vki_u_int16_t   reserved73;
   vki_u_int16_t   reserved74;
   /*075*/ vki_u_int16_t   queue;
   /*76*/  vki_u_int16_t   satacapabilities;
   /*77*/  vki_u_int16_t   satacapabilities2;
   /*78*/  vki_u_int16_t   satasupport;
   /*79*/  vki_u_int16_t   sataenabled;
   /*080*/ vki_u_int16_t   version_major;
   /*081*/ vki_u_int16_t   version_minor;

   struct {
      /*082/085*/ vki_u_int16_t   command1;
      /*083/086*/ vki_u_int16_t   command2;
      /*084/087*/ vki_u_int16_t   extension;
   } __packed support, enabled;

   /*088*/ vki_u_int16_t   udmamodes;              /* UltraDMA modes */
   /*089*/ vki_u_int16_t   erase_time;
   /*090*/ vki_u_int16_t   enhanced_erase_time;
   /*091*/ vki_u_int16_t   apm_value;
   /*092*/ vki_u_int16_t   master_passwd_revision;
   /*093*/ vki_u_int16_t   hwres;
   /*094*/ vki_u_int16_t   acoustic;
   /*095*/ vki_u_int16_t   stream_min_req_size;
   /*096*/ vki_u_int16_t   stream_transfer_time;
   /*097*/ vki_u_int16_t   stream_access_latency;
   /*098*/ vki_u_int32_t   stream_granularity;
   /*100*/ vki_u_int16_t   lba_size48_1;
   vki_u_int16_t   lba_size48_2;
   vki_u_int16_t   lba_size48_3;
   vki_u_int16_t   lba_size48_4;
   vki_u_int16_t   reserved104;
   /*105*/ vki_u_int16_t   max_dsm_blocks;
   /*106*/ vki_u_int16_t   pss;
   /*107*/ vki_u_int16_t   isd;
   /*108*/ vki_u_int16_t   wwn[4];
   vki_u_int16_t   reserved112[5];
   /*117*/ vki_u_int16_t   lss_1;
   /*118*/ vki_u_int16_t   lss_2;
   /*119*/ vki_u_int16_t   support2;
   /*120*/ vki_u_int16_t   enabled2;
   vki_u_int16_t   reserved121[6];
   /*127*/ vki_u_int16_t   removable_status;
   /*128*/ vki_u_int16_t   security_status;
   vki_u_int16_t   reserved129[31];
   /*160*/ vki_u_int16_t   cfa_powermode1;
   vki_u_int16_t   reserved161;
   /*162*/ vki_u_int16_t   cfa_kms_support;
   /*163*/ vki_u_int16_t   cfa_trueide_modes;
   /*164*/ vki_u_int16_t   cfa_memory_modes;
   vki_u_int16_t   reserved165[4];
   /*169*/ vki_u_int16_t   support_dsm;
   vki_u_int16_t   reserved170[6];
   /*176*/ vki_u_int8_t    media_serial[60];
   /*206*/ vki_u_int16_t   sct;
   vki_u_int16_t   reserved206[2];
   /*209*/ vki_u_int16_t   lsalign;
   /*210*/ vki_u_int16_t   wrv_sectors_m3_1;
   vki_u_int16_t   wrv_sectors_m3_2;
   /*212*/ vki_u_int16_t   wrv_sectors_m2_1;
   vki_u_int16_t   wrv_sectors_m2_2;
   /*214*/ vki_u_int16_t   nv_cache_caps;
   /*215*/ vki_u_int16_t   nv_cache_size_1;
   vki_u_int16_t   nv_cache_size_2;
   /*217*/ vki_u_int16_t   media_rotation_rate;
   vki_u_int16_t   reserved218;
   /*219*/ vki_u_int16_t   nv_cache_opt;
   /*220*/ vki_u_int16_t   wrv_mode;
   vki_u_int16_t   reserved221;
   /*222*/ vki_u_int16_t   transport_major;
   /*223*/ vki_u_int16_t   transport_minor;
   vki_u_int16_t   reserved224[31];
   /*255*/ vki_u_int16_t   integrity;
} __packed;

//----------------------------------------------------------------------
// From sys/callout.h
//----------------------------------------------------------------------

struct vki_callout_handle {
   struct vki_callout *callout;
};


//----------------------------------------------------------------------
// From cam/scsi/scsi_all.h
//----------------------------------------------------------------------

struct vki_scsi_sense_data {
   vki_u_int8_t error_code;
   vki_u_int8_t segment;
   vki_u_int8_t flags;
   vki_u_int8_t info[4];
   vki_u_int8_t extra_len;
   vki_u_int8_t cmd_spec_info[4];
   vki_u_int8_t add_sense_code;
   vki_u_int8_t add_sense_code_qual;
   vki_u_int8_t fru;
   vki_u_int8_t sense_key_spec[3];
   vki_u_int8_t extra_bytes[14];
#define VKI_SSD_FULL_SIZE sizeof(struct vki_scsi_sense_data)
};

struct vki_scsi_inquiry_data {
   vki_uint8_t device;
   vki_uint8_t dev_qual2;
   vki_uint8_t version;
   vki_uint8_t response_format;
   vki_uint8_t additional_length;
   vki_uint8_t spc3_flags;
   vki_uint8_t spc2_flags;
   vki_uint8_t flags;
#define VKI_SID_VENDOR_SIZE   8
   char     vendor[VKI_SID_VENDOR_SIZE];
#define VKI_SID_PRODUCT_SIZE  16
   char     product[VKI_SID_PRODUCT_SIZE];
#define VKI_SID_REVISION_SIZE 4
   char     revision[VKI_SID_REVISION_SIZE];
#define VKI_SID_VENDOR_SPECIFIC_0_SIZE      20
   vki_uint8_t vendor_specific0[VKI_SID_VENDOR_SPECIFIC_0_SIZE];
   vki_uint8_t spi3data;
   vki_uint8_t reserved2;
   /*
    * Version Descriptors, stored 2 byte values.
    */
   vki_uint8_t version1[2];
   vki_uint8_t version2[2];
   vki_uint8_t version3[2];
   vki_uint8_t version4[2];
   vki_uint8_t version5[2];
   vki_uint8_t version6[2];
   vki_uint8_t version7[2];
   vki_uint8_t version8[2];

   vki_uint8_t reserved3[22];

#define VKI_SID_VENDOR_SPECIFIC_1_SIZE      160
   vki_uint8_t vendor_specific1[VKI_SID_VENDOR_SPECIFIC_1_SIZE];
};

//----------------------------------------------------------------------
// From sys/queue.h
//----------------------------------------------------------------------

#define SLIST_ENTRY(type)                                               \
struct {                                                                \
        struct type *sle_next;  /* next element */                      \
}

#define LIST_ENTRY(type)                                                \
struct {                                                                \
        struct type *le_next;   /* next element */                      \
        struct type **le_prev;  /* address of previous next element */  \
}

#define STAILQ_ENTRY(type)                                              \
struct {                                                                \
        struct type *stqe_next; /* next element */                      \
}

struct qm_trace {
   unsigned long    lastline;
   unsigned long    prevline;
   const char      *lastfile;
   const char      *prevfile;
};

#define TRACEBUF        struct qm_trace trace;

#define TAILQ_ENTRY(type)                                               \
struct {                                                                \
        struct type *tqe_next;  /* next element */                      \
        struct type **tqe_prev; /* address of previous next element */  \
        TRACEBUF                                                        \
}


//----------------------------------------------------------------------
// From cam/cam_ccb.h
//----------------------------------------------------------------------

#define VKI_CAM_VERSION       0x15    /* Hex value for current version */

typedef union {
   LIST_ENTRY(vki_ccb_hdr) le;
   SLIST_ENTRY(vki_ccb_hdr) sle;
   TAILQ_ENTRY(vki_ccb_hdr) tqe;
   STAILQ_ENTRY(vki_ccb_hdr) stqe;
} vki_camq_entry;

typedef enum {
   /* Function code flags are bits greater than 0xff */
   VKI_XPT_FC_QUEUED           = 0x100,
   /* Non-immediate function code */
   VKI_XPT_FC_USER_CCB         = 0x200,
   VKI_XPT_FC_XPT_ONLY         = 0x400,
   /* Only for the transport layer device */
   VKI_XPT_FC_DEV_QUEUED       = 0x800 | VKI_XPT_FC_QUEUED,
   /* Passes through the device queues */
   /* Common function commands: 0x00->0x0F */
   VKI_XPT_NOOP                = 0x00,
   /* Execute Nothing */
   VKI_XPT_SCSI_IO             = 0x01 | VKI_XPT_FC_DEV_QUEUED,
   /* Execute the requested I/O operation */
   VKI_XPT_GDEV_TYPE           = 0x02,
   /* Get type information for specified device */
   VKI_XPT_GDEVLIST            = 0x03,
   /* Get a list of peripheral devices */
   VKI_XPT_PATH_INQ            = 0x04,
   /* Path routing inquiry */
   VKI_XPT_REL_SIMQ            = 0x05,
   /* Release a frozen device queue */
   VKI_XPT_SASYNC_CB           = 0x06,
   /* Set Asynchronous Callback Parameters */
   VKI_XPT_SDEV_TYPE           = 0x07,
   /* Set device type information */
   VKI_XPT_SCAN_BUS            = 0x08 | VKI_XPT_FC_QUEUED | VKI_XPT_FC_USER_CCB
                                 | VKI_XPT_FC_XPT_ONLY,
   /* (Re)Scan the SCSI Bus */
   VKI_XPT_DEV_MATCH           = 0x09 | VKI_XPT_FC_XPT_ONLY,
   /* Get EDT entries matching the given pattern */
   VKI_XPT_DEBUG               = 0x0a,
   /* Turn on debugging for a bus, target or lun */
   VKI_XPT_PATH_STATS          = 0x0b,
   /* Path statistics (error counts, etc.) */
   VKI_XPT_GDEV_STATS          = 0x0c,
   /* Device statistics (error counts, etc.) */
   VKI_XPT_FREEZE_QUEUE        = 0x0d,
   /* Freeze device queue */
   /* SCSI Control Functions: 0x10->0x1F */
   VKI_XPT_ABORT               = 0x10,
   /* Abort the specified CCB */
   VKI_XPT_RESET_BUS           = 0x11 | VKI_XPT_FC_XPT_ONLY,
   /* Reset the specified SCSI bus */
   VKI_XPT_RESET_DEV           = 0x12 | VKI_XPT_FC_DEV_QUEUED,
   /* Bus Device Reset the specified SCSI device */
   VKI_XPT_TERM_IO             = 0x13,
   /* Terminate the I/O process */
   VKI_XPT_SCAN_LUN            = 0x14 | VKI_XPT_FC_QUEUED | VKI_XPT_FC_USER_CCB
                                 | VKI_XPT_FC_XPT_ONLY,
   /* Scan Logical Unit */
   VKI_XPT_GET_TRAN_SETTINGS   = 0x15,
   /*
    * Get default/user transfer settings
    * for the target
    */
   VKI_XPT_SET_TRAN_SETTINGS   = 0x16,
   /*
    * Set transfer rate/width
    * negotiation settings
    */
   VKI_XPT_CALC_GEOMETRY       = 0x17,
   /*
    * Calculate the geometry parameters for
    * a device give the sector size and
    * volume size.
    */
   VKI_XPT_ATA_IO              = 0x18 | VKI_XPT_FC_DEV_QUEUED,
   /* Execute the requested ATA I/O operation */
   VKI_XPT_GET_SIM_KNOB        = 0x18,
   /*
    * Get SIM specific knob values.
    */

   VKI_XPT_SET_SIM_KNOB        = 0x19,
   /*
    * Set SIM specific knob values.
    */
   /* HBA engine commands 0x20->0x2F */
   VKI_XPT_ENG_INQ             = 0x20 | VKI_XPT_FC_XPT_ONLY,
   /* HBA engine feature inquiry */
   VKI_XPT_ENG_EXEC            = 0x21 | VKI_XPT_FC_DEV_QUEUED,
   /* HBA execute engine request */

   /* Target mode commands: 0x30->0x3F */
   VKI_XPT_EN_LUN              = 0x30,
   /* Enable LUN as a target */
   VKI_XPT_TARGET_IO           = 0x31 | VKI_XPT_FC_DEV_QUEUED,
   /* Execute target I/O request */
   VKI_XPT_ACCEPT_TARGET_IO    = 0x32 | VKI_XPT_FC_QUEUED | VKI_XPT_FC_USER_CCB,
   /* Accept Host Target Mode CDB */
   VKI_XPT_CONT_TARGET_IO      = 0x33 | VKI_XPT_FC_DEV_QUEUED,
   /* Continue Host Target I/O Connection */
   VKI_XPT_IMMED_NOTIFY        = 0x34 | VKI_XPT_FC_QUEUED | VKI_XPT_FC_USER_CCB,
   /* Notify Host Target driver of event (obsolete) */
   VKI_XPT_NOTIFY_ACK          = 0x35,
   /* Acknowledgement of event (obsolete) */
   VKI_XPT_IMMEDIATE_NOTIFY    = 0x36 | VKI_XPT_FC_QUEUED | VKI_XPT_FC_USER_CCB,
   /* Notify Host Target driver of event */
   VKI_XPT_NOTIFY_ACKNOWLEDGE  = 0x37 | VKI_XPT_FC_QUEUED | VKI_XPT_FC_USER_CCB,
   /* Acknowledgement of event */

   /* Vendor Unique codes: 0x80->0x8F */
   VKI_XPT_VUNIQUE             = 0x80
} vki_xpt_opcode;


/* CAM CCB flags */
typedef enum {
   VKI_CAM_CDB_POINTER         = 0x00000001,/* The CDB field is a pointer    */
   VKI_CAM_QUEUE_ENABLE        = 0x00000002,/* SIM queue actions are enabled */
   VKI_CAM_CDB_LINKED          = 0x00000004,/* CCB contains a linked CDB     */
   VKI_CAM_NEGOTIATE           = 0x00000008,/*
                                              * Perform transport negotiation
                                              * with this command.
                                              */
   VKI_CAM_SCATTER_VALID       = 0x00000010,/* Scatter/gather list is valid  */
   VKI_CAM_DIS_AUTOSENSE       = 0x00000020,/* Disable autosense feature     */
   VKI_CAM_DIR_RESV            = 0x00000000,/* Data direction (00:reserved)  */
   VKI_CAM_DIR_IN              = 0x00000040,/* Data direction (01:DATA IN)   */
   VKI_CAM_DIR_OUT             = 0x00000080,/* Data direction (10:DATA OUT)  */
   VKI_CAM_DIR_NONE            = 0x000000C0,/* Data direction (11:no data)   */
   VKI_CAM_DIR_MASK            = 0x000000C0,/* Data direction Mask           */
   VKI_CAM_SOFT_RST_OP         = 0x00000100,/* Use Soft reset alternative    */
   VKI_CAM_ENG_SYNC            = 0x00000200,/* Flush resid bytes on complete */
   VKI_CAM_DEV_QFRZDIS         = 0x00000400,/* Disable DEV Q freezing        */
   VKI_CAM_DEV_QFREEZE         = 0x00000800,/* Freeze DEV Q on execution     */
   VKI_CAM_HIGH_POWER          = 0x00001000,/* Command takes a lot of power  */
   VKI_CAM_SENSE_PTR           = 0x00002000,/* Sense data is a pointer       */
   VKI_CAM_SENSE_PHYS          = 0x00004000,/* Sense pointer is physical addr*/
   VKI_CAM_TAG_ACTION_VALID    = 0x00008000,/* Use the tag action in this ccb*/
   VKI_CAM_PASS_ERR_RECOVER    = 0x00010000,/* Pass driver does err. recovery*/
   VKI_CAM_DIS_DISCONNECT      = 0x00020000,/* Disable disconnect            */
   VKI_CAM_SG_LIST_PHYS        = 0x00040000,/* SG list has physical addrs.   */
   VKI_CAM_MSG_BUF_PHYS        = 0x00080000,/* Message buffer ptr is physical*/
   VKI_CAM_SNS_BUF_PHYS        = 0x00100000,/* Autosense data ptr is physical*/
   VKI_CAM_DATA_PHYS           = 0x00200000,/* SG/Buffer data ptrs are phys. */
   VKI_CAM_CDB_PHYS            = 0x00400000,/* CDB poiner is physical        */
   VKI_CAM_ENG_SGLIST          = 0x00800000,/* SG list is for the HBA engine */

   /* Phase cognizant mode flags */
   VKI_CAM_DIS_AUTOSRP         = 0x01000000,/* Disable autosave/restore ptrs */
   VKI_CAM_DIS_AUTODISC        = 0x02000000,/* Disable auto disconnect       */
   VKI_CAM_TGT_CCB_AVAIL       = 0x04000000,/* Target CCB available          */
   VKI_CAM_TGT_PHASE_MODE      = 0x08000000,/* The SIM runs in phase mode    */
   VKI_CAM_MSGB_VALID          = 0x10000000,/* Message buffer valid          */
   VKI_CAM_STATUS_VALID        = 0x20000000,/* Status buffer valid           */
   VKI_CAM_DATAB_VALID         = 0x40000000,/* Data buffer valid             */

   /* Host target Mode flags */
   VKI_CAM_SEND_SENSE          = 0x08000000,/* Send sense data with status   */
   VKI_CAM_TERM_IO             = 0x10000000,/* Terminate I/O Message sup.    */
   VKI_CAM_DISCONNECT          = 0x20000000,/* Disconnects are mandatory     */
   VKI_CAM_SEND_STATUS         = 0x40000000 /* Send status after data phase  */
} vki_ccb_flags;

typedef union {
   void            *ptr;
   vki_u_long      field;
   vki_uint8_t     bytes[sizeof(vki_uintptr_t)];
} vki_ccb_priv_entry;

#define VKI_IOCDBLEN  VKI_CAM_MAX_CDBLEN  /* Space for CDB bytes/pointer */
#define VKI_CCB_PERIPH_PRIV_SIZE    2   /* size of peripheral private area */
#define VKI_CCB_SIM_PRIV_SIZE       2   /* size of sim private area */

typedef union {
   vki_ccb_priv_entry entries[VKI_CCB_PERIPH_PRIV_SIZE];
   vki_uint8_t        bytes[VKI_CCB_PERIPH_PRIV_SIZE * sizeof(vki_ccb_priv_entry)];
} vki_ccb_ppriv_area;

typedef union {
   vki_ccb_priv_entry entries[VKI_CCB_SIM_PRIV_SIZE];
   vki_uint8_t        bytes[VKI_CCB_SIM_PRIV_SIZE * sizeof(vki_ccb_priv_entry)];
} vki_ccb_spriv_area;

union vki_ccb;
struct vki_cam_periph;

struct vki_ccb_hdr {
   vki_cam_pinfo   pinfo;          /* Info for priority scheduling */
   vki_camq_entry  xpt_links;      /* For chaining in the XPT layer */
   vki_camq_entry  sim_links;      /* For chaining in the SIM layer */
   vki_camq_entry  periph_links;   /* For chaining in the type driver */
   vki_uint32_t    retry_count;
   void         (*cbfcnp)(struct vki_cam_periph *, union vki_ccb *);
   /* Callback on completion function */
   vki_xpt_opcode  func_code;      /* XPT function code */
   vki_uint32_t    status;         /* Status returned by CAM subsystem */
   struct      vki_cam_path *path; /* Compiled path for this ccb */
   vki_path_id_t   path_id;        /* Path ID for the request */
   vki_target_id_t target_id;      /* Target device ID */
   vki_lun_id_t    target_lun;     /* Target LUN number */
   vki_uint32_t    flags;          /* ccb_flags */
   vki_ccb_ppriv_area  periph_priv;
   vki_ccb_spriv_area  sim_priv;
   vki_uint32_t    timeout;        /* Timeout value */

   /*
    * Deprecated, only for use by non-MPSAFE SIMs.  All others must
    * allocate and initialize their own callout storage.
    */
   struct      vki_callout_handle timeout_ch;
};

typedef union {
   vki_u_int8_t  *cdb_ptr;             /* Pointer to the CDB bytes to send */
   /* Area for the CDB send */
   vki_u_int8_t  cdb_bytes[VKI_IOCDBLEN];
} vki_cdb_t;


/*
 * SCSI I/O Request CCB used for the XPT_SCSI_IO and XPT_CONT_TARGET_IO
 * function codes.
 */
struct vki_ccb_scsiio {
   struct     vki_ccb_hdr ccb_h;
   union      vki_ccb *next_ccb;   /* Ptr for next CCB for action */
   vki_u_int8_t   *req_map;        /* Ptr to mapping info */
   vki_u_int8_t   *data_ptr;       /* Ptr to the data buf/SG list */
   vki_u_int32_t  dxfer_len;       /* Data transfer length */
   /* Autosense storage */
   struct     vki_scsi_sense_data sense_data;
   vki_u_int8_t   sense_len;       /* Number of bytes to autosense */
   vki_u_int8_t   cdb_len;         /* Number of bytes for the CDB */
   vki_u_int16_t  sglist_cnt;      /* Number of SG list entries */
   vki_u_int8_t   scsi_status;     /* Returned SCSI status */
   vki_u_int8_t   sense_resid;     /* Autosense resid length: 2's comp */
   vki_u_int32_t  resid;           /* Transfer residual length: 2's comp */
   vki_cdb_t      cdb_io;          /* Union for CDB bytes/pointer */
   vki_u_int8_t   *msg_ptr;        /* Pointer to the message buffer */
   vki_u_int16_t  msg_len;         /* Number of bytes for the Message */
   vki_u_int8_t   tag_action;      /* What to do for tag queueing */
   /*
    * The tag action should be either the define below (to send a
    * non-tagged transaction) or one of the defined scsi tag messages
    * from scsi_message.h.
    */
   vki_u_int      tag_id;          /* tag id from initator (target mode) */
   vki_u_int      init_id;         /* initiator id of who selected */
};

typedef enum {
   VKI_CAM_DEV_MATCH_LAST,
   VKI_CAM_DEV_MATCH_MORE,
   VKI_CAM_DEV_MATCH_LIST_CHANGED,
   VKI_CAM_DEV_MATCH_SIZE_ERROR,
   VKI_CAM_DEV_MATCH_ERROR
} vki_ccb_dev_match_status;


struct vki_dev_match_pattern;

typedef enum {
   VKI_DEV_MATCH_PERIPH,
   VKI_DEV_MATCH_DEVICE,
   VKI_DEV_MATCH_BUS
} vki_dev_match_type;

#define VKI_DEV_IDLEN       16          /* ASCII string len for device names */

struct vki_periph_match_result {
   char                    periph_name[VKI_DEV_IDLEN];
   vki_uint32_t            unit_number;
   vki_path_id_t           path_id;
   vki_target_id_t         target_id;
   vki_lun_id_t            target_lun;
};

typedef enum {
   VKI_PROTO_UNKNOWN,
   VKI_PROTO_UNSPECIFIED,
   VKI_PROTO_SCSI,     /* Small Computer System Interface */
   VKI_PROTO_ATA,      /* AT Attachment */
   VKI_PROTO_ATAPI,    /* AT Attachment Packetized Interface */
   VKI_PROTO_SATAPM,   /* SATA Port Multiplier */
} vki_cam_proto;

typedef enum {
   VKI_DEV_RESULT_NOFLAG               = 0x00,
   VKI_DEV_RESULT_UNCONFIGURED         = 0x01
} vki_dev_result_flags;


struct vki_device_match_result {
   vki_path_id_t                   path_id;
   vki_target_id_t                 target_id;
   vki_lun_id_t                    target_lun;
   vki_cam_proto                   protocol;
   struct vki_scsi_inquiry_data    inq_data;
   struct vki_ata_params           ident_data;
   vki_dev_result_flags            flags;
};

struct vki_bus_match_result {
   vki_path_id_t   path_id;
   char            dev_name[VKI_DEV_IDLEN];
   vki_uint32_t    unit_number;
   vki_uint32_t    bus_id;
};

union vki_match_result {
   struct vki_periph_match_result      periph_result;
   struct vki_device_match_result      device_result;
   struct vki_bus_match_result         bus_result;
};

struct vki_dev_match_result {
   vki_dev_match_type          type;
   union vki_match_result      result;
};

typedef enum {
   VKI_CAM_DEV_POS_NONE        = 0x000,
   VKI_CAM_DEV_POS_BUS         = 0x001,
   VKI_CAM_DEV_POS_TARGET      = 0x002,
   VKI_CAM_DEV_POS_DEVICE      = 0x004,
   VKI_CAM_DEV_POS_PERIPH      = 0x008,
   VKI_CAM_DEV_POS_PDPTR       = 0x010,
   VKI_CAM_DEV_POS_TYPEMASK    = 0xf00,
   VKI_CAM_DEV_POS_EDT         = 0x100,
   VKI_CAM_DEV_POS_PDRV        = 0x200
} vki_dev_pos_type;

struct vki_ccb_dm_cookie {
   void    *bus;
   void    *target;
   void    *device;
   void    *periph;
   void    *pdrv;
};

struct vki_ccb_dev_position {
   vki_u_int                generations[4];
#define VKI_CAM_BUS_GENERATION      0x00
#define VKI_CAM_TARGET_GENERATION   0x01
#define VKI_CAM_DEV_GENERATION      0x02
#define VKI_CAM_PERIPH_GENERATION   0x03
   vki_dev_pos_type        position_type;
   struct vki_ccb_dm_cookie cookie;
};

struct vki_ccb_dev_match {
   struct vki_ccb_hdr              ccb_h;
   vki_ccb_dev_match_status        status;
   vki_uint32_t                    num_patterns;
   vki_uint32_t                    pattern_buf_len;
   struct vki_dev_match_pattern    *patterns;
   vki_uint32_t                    num_matches;
   vki_uint32_t                    match_buf_len;
   struct vki_dev_match_result     *matches;
   struct vki_ccb_dev_position     pos;
};

/*
 * Union of all CCB types for kernel space allocation.  This union should
 * never be used for manipulating CCBs - its only use is for the allocation
 * and deallocation of raw CCB space and is the return type of xpt_ccb_alloc
 * and the argument to xpt_ccb_free.
 */
union vki_ccb {
   /* Only letting out ones currently handled */
   struct  vki_ccb_hdr             ccb_h;  /* For convenience */
   struct  vki_ccb_scsiio          csio;
#if 0
   struct  ccb_getdev              cgd;
   struct  ccb_getdevlist          cgdl;
   struct  ccb_pathinq             cpi;
   struct  ccb_relsim              crs;
   struct  ccb_setasync            csa;
   struct  ccb_setdev              csd;
   struct  ccb_pathstats           cpis;
   struct  ccb_getdevstats         cgds;
#endif
   struct  vki_ccb_dev_match       cdm;
#if 0
   struct  ccb_trans_settings      cts;
   struct  ccb_calc_geometry       ccg;
   struct  ccb_sim_knob            knob;
   struct  ccb_abort               cab;
   struct  ccb_resetbus            crb;
   struct  ccb_resetdev            crd;
   struct  ccb_termio              tio;
   struct  ccb_accept_tio          atio;
   struct  ccb_scsiio              ctio;
   struct  ccb_en_lun              cel;
   struct  ccb_immed_notify        cin;
   struct  ccb_notify_ack          cna;
   struct  ccb_immediate_notify    cin1;
   struct  ccb_notify_acknowledge  cna2;
   struct  ccb_eng_inq             cei;
   struct  ccb_eng_exec            cee;
   struct  ccb_rescan              crcn;
   struct  ccb_debug               cdbg;
   struct  ccb_ataio               ataio;
#endif
   char make_union_right_size[0x4A8];
};

#define VKI_CAMIOCOMMAND    _VKI_IOWR(VKI_CAM_VERSION, 2, union vki_ccb)

#endif
/*--------------------------------------------------------------------*/
/*--- end                                                          ---*/
/*--------------------------------------------------------------------*/
